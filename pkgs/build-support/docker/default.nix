{
  callPackage,
  buildEnv,
  coreutils,
  docker,
  e2fsprogs,
  findutils,
  go,
  jshon,
  jq,
  lib,
  pkgs,
  pigz,
  nixUnstable,
  perl,
  python3,
  runCommand,
  rsync,
  shadow,
  stdenv,
  storeDir ? builtins.storeDir,
  utillinux,
  vmTools,
  writeReferencesToFile,
  writeScript,
  writeText,
}:

# WARNING: this API is unstable and may be subject to backwards-incompatible changes in the future.

rec {

  examples = import ./examples.nix {
    inherit pkgs buildImage pullImage shadowSetup buildImageWithNixDb;
  };

  pullImage = callPackage ./pull.nix {};

  # We need to sum layer.tar, not a directory, hence tarsum instead of nix-hash.
  # And we cannot untar it, because then we cannot preserve permissions ecc.
  tarsum = runCommand "tarsum" {
    buildInputs = [ go ];
  } ''
    mkdir tarsum
    cd tarsum

    cp ${./tarsum.go} tarsum.go
    export GOPATH=$(pwd)
    mkdir -p src/github.com/docker/docker/pkg
    ln -sT ${docker.src}/components/engine/pkg/tarsum src/github.com/docker/docker/pkg/tarsum
    go build

    cp tarsum $out
  '';

  # buildEnv creates symlinks to dirs, which is hard to edit inside the overlay VM
  mergeDrvs = {
    derivations,
    onlyDeps ? false
  }:
    runCommand "merge-drvs" {
      inherit derivations onlyDeps;
    } ''
      if [[ -n "$onlyDeps" ]]; then
        echo $derivations > $out
        exit 0
      fi

      mkdir $out
      for derivation in $derivations; do
        echo "Merging $derivation..."
        if [[ -d "$derivation" ]]; then
          # If it's a directory, copy all of its contents into $out.
          cp -drf --preserve=mode -f $derivation/* $out/
        else
          # Otherwise treat the derivation as a tarball and extract it
          # into $out.
          tar -C $out -xpf $drv || true
        fi
      done
    '';

  # Helper for setting up the base files for managing users and
  # groups, only if such files don't exist already. It is suitable for
  # being used in a runAsRoot script.
  shadowSetup = ''
    export PATH=${shadow}/bin:$PATH
    mkdir -p /etc/pam.d
    if [[ ! -f /etc/passwd ]]; then
      echo "root:x:0:0::/root:${stdenv.shell}" > /etc/passwd
      echo "root:!x:::::::" > /etc/shadow
    fi
    if [[ ! -f /etc/group ]]; then
      echo "root:x:0:" > /etc/group
      echo "root:x::" > /etc/gshadow
    fi
    if [[ ! -f /etc/pam.d/other ]]; then
      cat > /etc/pam.d/other <<EOF
    account sufficient pam_unix.so
    auth sufficient pam_rootok.so
    password requisite pam_unix.so nullok sha512
    session required pam_unix.so
    EOF
    fi
    if [[ ! -f /etc/login.defs ]]; then
      touch /etc/login.defs
    fi
  '';

  # Run commands in a virtual machine.
  runWithOverlay = {
    name,
    fromImage ? null,
    fromImageName ? null,
    fromImageTag ? null,
    diskSize ? 1024,
    preMount ? "",
    postMount ? "",
    postUmount ? ""
  }:
    vmTools.runInLinuxVM (
      runCommand name {
        preVM = vmTools.createEmptyImage {
          size = diskSize;
          fullName = "docker-run-disk";
        };
        inherit fromImage fromImageName fromImageTag;

        buildInputs = [ utillinux e2fsprogs jshon rsync ];
      } ''
      rm -rf $out

      mkdir disk
      mkfs /dev/${vmTools.hd}
      mount /dev/${vmTools.hd} disk
      cd disk

      if [[ -n "$fromImage" ]]; then
        echo "Unpacking base image..."
        mkdir image
        tar -C image -xpf "$fromImage"

        # If the image name isn't set, read it from the image repository json.
        if [[ -z "$fromImageName" ]]; then
          fromImageName=$(jshon -k < image/repositories | head -n 1)
          echo "From-image name wasn't set. Read $fromImageName."
        fi

        # If the tag isn't set, use the name as an index into the json
        # and read the first key found.
        if [[ -z "$fromImageTag" ]]; then
          fromImageTag=$(jshon -e $fromImageName -k < image/repositories \
                         | head -n1)
          echo "From-image tag wasn't set. Read $fromImageTag."
        fi

        # Use the name and tag to get the parent ID field.
        parentID=$(jshon -e $fromImageName -e $fromImageTag -u \
                   < image/repositories)
      fi

      # Unpack all of the parent layers into the image.
      lowerdir=""
      while [[ -n "$parentID" ]]; do
        echo "Unpacking layer $parentID"
        mkdir -p image/$parentID/layer
        tar -C image/$parentID/layer -xpf image/$parentID/layer.tar
        rm image/$parentID/layer.tar

        find image/$parentID/layer -name ".wh.*" -exec bash -c 'name="$(basename {}|sed "s/^.wh.//")"; mknod "$(dirname {})/$name" c 0 0; rm {}' \;

        # Get the next lower directory and continue the loop.
        lowerdir=$lowerdir''${lowerdir:+:}image/$parentID/layer
        parentID=$(cat image/$parentID/json \
                  | (jshon -e parent -u 2>/dev/null || true))
      done

      mkdir work
      mkdir layer
      mkdir mnt

      ${lib.optionalString (preMount != "") ''
        # Execute pre-mount steps
        echo "Executing pre-mount steps..."
        ${preMount}
      ''}

      if [ -n "$lowerdir" ]; then
        mount -t overlay overlay -olowerdir=$lowerdir,workdir=work,upperdir=layer mnt
      else
        mount --bind layer mnt
      fi

      ${lib.optionalString (postMount != "") ''
        # Execute post-mount steps
        echo "Executing post-mount steps..."
        ${postMount}
      ''}

      umount mnt

      (
        cd layer
        cmd='name="$(basename {})"; touch "$(dirname {})/.wh.$name"; rm "{}"'
        find . -type c -exec bash -c "$cmd" \;
      )

      ${postUmount}
      '');

  exportImage = { name ? fromImage.name, fromImage, fromImageName ? null, fromImageTag ? null, diskSize ? 1024 }:
    runWithOverlay {
      inherit name fromImage fromImageName fromImageTag diskSize;

      postMount = ''
        echo "Packing raw image..."
        tar -C mnt --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" -cf $out .
      '';
    };


  # Create an executable shell script which has the coreutils in its
  # PATH. Since root scripts are executed in a blank environment, even
  # things like `ls` or `echo` will be missing.
  shellScript = name: text:
    writeScript name ''
      #!${stdenv.shell}
      set -e
      export PATH=${coreutils}/bin:/bin
      ${text}
    '';

  nixRegistration = contents: runCommand "nix-registration" {
    buildInputs = [ nixUnstable perl ];
    # For obtaining the closure of `contents'.
    exportReferencesGraph =
      let contentsList = if builtins.isList contents then contents else [ contents ];
      in map (x: [("closure-" + baseNameOf x) x]) contentsList;
    }
    ''
      mkdir $out
      printRegistration=1 perl ${pkgs.pathsFromGraph} closure-* > $out/db.dump
      perl ${pkgs.pathsFromGraph} closure-* > $out/storePaths
    '';

  # Create a "layer" (set of files).
  mkManyPureLayers = {
    name,
    # Files to add to the layer.
    contents,
    baseJson,
    uid ? 0, gid ? 0,
    # Docker has a 42-layer maximum, we pick 24 to ensure there is plenty
    # of room for extension
    maxLayers ? 24
  }:
    runCommand "${name}-granular-docker-layers" {
      inherit maxLayers;
      paths = pathsFromGraphByPopularity contents;
      buildInputs = [ jshon rsync ];
      enableParallelBuilding = true;
    }
    ''
      # Delete impurities for store path layers, so they don't get
      # shared and taint other projects.
      cat ${baseJson} \
        | jshon -d config \
        | jshon -s "1970-01-01T00:00:01Z" -i created > generic.json

      # WARNING!
      # The following code is fiddly w.r.t. ensuring every layer is
      # created, and that no paths are missed. If you change the
      # following head and tail call lines, double-check that your
      # code behaves properly when the number of layers equals:
      #      maxLayers-1, maxLayers, and maxLayers+1
      head -n $((maxLayers - 1)) $paths | cat -n | xargs -P$NIX_BUILD_CORES -n2 ${./store-path-to-layer.sh} ${tarsum}
      if [ $(cat $paths | wc -l) -ge $maxLayers ]; then
        tail -n+$maxLayers $paths | xargs ${./store-path-to-layer.sh} ${tarsum} $maxLayers
      fi

      echo "Finished building layer '$name'"

      mv ./layers $out
    '';

  # Create a "layer" (set of files).
  mkSymlinkLayer = {
    name,
    # Files to add to the layer.
    contents,
    baseJson,
    uid ? 0, gid ? 0,
  }:
    runCommand "${name}-symlink-layer" {
      buildInputs = [ jshon rsync ];
    }
    ''
      mkdir layer
      find ${contents} -maxdepth 1 -mindepth 1 -print0 | xargs -0 -I{} ln -s {} ./layer/

      # Tar up the layer and throw it into 'layer.tar'.
      echo "Packing layer..."
      mkdir $out
      tar -C layer --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=${toString uid} --group=${toString gid} -cf $out/layer.tar .

      # Compute a checksum of the tarball.
      echo "Computing layer checksum..."
      tarsum=$(${tarsum} < $out/layer.tar)

      # Add a 'checksum' field to the JSON, with the value set to the
      # checksum of the tarball.
      cat ${baseJson} | jshon -s "$tarsum" -i checksum > $out/json

      # Indicate to docker that we're using schema version 1.0.
      echo -n "1.0" > $out/VERSION
    '';

  # Create a "layer" (set of files).
  mkPureLayer = {
    # Name of the layer
    name,
    # JSON containing configuration and metadata for this layer.
    baseJson,
    # Files to add to the layer.
    contents ? null,
    # When copying the contents into the image, preserve symlinks to
    # directories (see `rsync -K`).  Otherwise, transform those symlinks
    # into directories.
    keepContentsDirlinks ? false,
    # Additional commands to run on the layer before it is tar'd up.
    extraCommands ? "", uid ? 0, gid ? 0
  }:
    runCommand "docker-layer-${name}" {
      inherit baseJson contents extraCommands;
      buildInputs = [ jshon rsync ];
    }
    ''
      mkdir layer
      if [[ -n "$contents" ]]; then
        echo "Adding contents..."
        for item in $contents; do
          echo "Adding $item"
          rsync -a${if keepContentsDirlinks then "K" else "k"} --chown=0:0 $item/ layer/
        done
      else
        echo "No contents to add to layer."
      fi

      chmod ug+w layer

      if [[ -n $extraCommands ]]; then
        (cd layer; eval "$extraCommands")
      fi

      # Tar up the layer and throw it into 'layer.tar'.
      echo "Packing layer..."
      mkdir $out
      tar -C layer --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=${toString uid} --group=${toString gid} -cf $out/layer.tar .

      # Compute a checksum of the tarball.
      echo "Computing layer checksum..."
      tarsum=$(${tarsum} < $out/layer.tar)

      # Add a 'checksum' field to the JSON, with the value set to the
      # checksum of the tarball.
      cat ${baseJson} | jshon -s "$tarsum" -i checksum > $out/json

      # Indicate to docker that we're using schema version 1.0.
      echo -n "1.0" > $out/VERSION

      echo "Finished building layer '${name}'"
    '';

  # Make a "root" layer; required if we need to execute commands as a
  # privileged user on the image. The commands themselves will be
  # performed in a virtual machine sandbox.
  mkRootLayer = {
    # Name of the image.
    name,
    # Script to run as root. Bash.
    runAsRoot,
    # Files to add to the layer. If null, an empty layer will be created.
    contents ? null,
    # When copying the contents into the image, preserve symlinks to
    # directories (see `rsync -K`).  Otherwise, transform those symlinks
    # into directories.
    keepContentsDirlinks ? false,
    # JSON containing configuration and metadata for this layer.
    baseJson,
    # Existing image onto which to append the new layer.
    fromImage ? null,
    # Name of the image we're appending onto.
    fromImageName ? null,
    # Tag of the image we're appending onto.
    fromImageTag ? null,
    # How much disk to allocate for the temporary virtual machine.
    diskSize ? 1024,
    # Commands (bash) to run on the layer; these do not require sudo.
    extraCommands ? ""
  }:
    # Generate an executable script from the `runAsRoot` text.
    let runAsRootScript = shellScript "run-as-root.sh" runAsRoot;
    in runWithOverlay {
      name = "docker-layer-${name}";

      inherit fromImage fromImageName fromImageTag diskSize;

      preMount = lib.optionalString (contents != null && contents != []) ''
        echo "Adding contents..."
        for item in ${toString contents}; do
          echo "Adding $item..."
          rsync -a${if keepContentsDirlinks then "K" else "k"} --chown=0:0 $item/ layer/
        done

        chmod ug+w layer
      '';

      postMount = ''
        mkdir -p mnt/{dev,proc,sys} mnt${storeDir}

        # Mount /dev, /sys and the nix store as shared folders.
        mount --rbind /dev mnt/dev
        mount --rbind /sys mnt/sys
        mount --rbind ${storeDir} mnt${storeDir}

        # Execute the run as root script. See 'man unshare' for
        # details on what's going on here; basically this command
        # means that the runAsRootScript will be executed in a nearly
        # completely isolated environment.
        unshare -imnpuf --mount-proc chroot mnt ${runAsRootScript}

        # Unmount directories and remove them.
        umount -R mnt/dev mnt/sys mnt${storeDir}
        rmdir --ignore-fail-on-non-empty \
          mnt/dev mnt/proc mnt/sys mnt${storeDir} \
          mnt$(dirname ${storeDir})
      '';

      postUmount = ''
        (cd layer; eval "${extraCommands}")

        echo "Packing layer..."
        mkdir $out
        tar -C layer --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" -cf $out/layer.tar .

        # Compute the tar checksum and add it to the output json.
        echo "Computing checksum..."
        ts=$(${tarsum} < $out/layer.tar)
        cat ${baseJson} | jshon -s "$ts" -i checksum > $out/json
        # Indicate to docker that we're using schema version 1.0.
        echo -n "1.0" > $out/VERSION

        echo "Finished building layer '${name}'"
      '';
    };

  # 1. extract the base image
  # 2. create the layer
  # 3. add layer deps to the layer itself, diffing with the base image
  # 4. compute the layer id
  # 5. put the layer in the image
  # 6. repack the image
  buildImage = args@{
    # Image name.
    name,
    # Image tag.
    tag ? "latest",
    # Parent image, to append to.
    fromImage ? null,
    # Name of the parent image; will be read from the image otherwise.
    fromImageName ? null,
    # Tag of the parent image; will be read from the image otherwise.
    fromImageTag ? null,
    # Files to put on the image (a nix store path or list of paths).
    contents ? null,
    # When copying the contents into the image, preserve symlinks to
    # directories (see `rsync -K`).  Otherwise, transform those symlinks
    # into directories.
    keepContentsDirlinks ? false,
    # Docker config; e.g. what command to run on the container.
    config ? null,
    # Optional bash script to run on the files prior to fixturizing the layer.
    extraCommands ? "", uid ? 0, gid ? 0,
    # Optional bash script to run as root on the image when provisioning.
    runAsRoot ? null,
    # Size of the virtual machine disk to provision when building the image.
    diskSize ? 1024,
    # Time of creation of the image.
    created ? "1970-01-01T00:00:01Z",
    # Docker has a 42-layer maximum, we pick 24 to ensure there is plenty
    # of room for extension
    maxLayers ? 24
  }:

    let
      contents' = buildEnv { inherit name; paths = contents; };
      baseName = baseNameOf name;

      # Create a JSON blob of the configuration. Set the date to unix zero.
      baseJson = writeText "${baseName}-config.json" (builtins.toJSON {
        inherit created config;
        architecture = "amd64";
        os = "linux";
      });

      bulkLayers = mkManyPureLayers {
          name = baseName;
          contents = contents';
          inherit baseJson uid gid maxLayers;
        };
      customizationLayer = mkSymlinkLayer {
          name = baseName;
          contents = contents';
          inherit baseJson uid gid;
        };
      result = runCommand "docker-image-${baseName}.tar.gz" {
        buildInputs = [ jshon pigz coreutils findutils jq ];
        # Image name and tag must be lowercase
        imageName = lib.toLower name;
        imageTag = if tag == null then "" else lib.toLower tag;
        inherit fromImage baseJson;
        passthru.buildArgs = args;
      } ''

        find ${bulkLayers} -mindepth 1 -maxdepth 1 | sort -t/ -k5 -n > layer-list
        echo ${customizationLayer} >> layer-list

        mkdir image
        imageJson=$(cat ${baseJson} | jq ". + {\"rootfs\": {\"diff_ids\": [], \"type\": \"layers\"}}")
        manifestJson=$(jq -n "[{\"RepoTags\":[\"$imageName:$imageTag\"]}]")
        for layer in $(cat layer-list); do
          layerChecksum=$(sha256sum $layer/layer.tar | cut -d ' ' -f1)
          layerID=$(sha256sum "$layer/json" | cut -d ' ' -f 1)
          cp -r "$layer" "./image/$layerID"

          manifestJson=$(echo "$manifestJson" | jq ".[0].Layers |= [\"$layerID/layer.tar\"] + .")
          imageJson=$(echo "$imageJson" | jq ".history |= [{\"created\": \"$(jq -r .created ${baseJson})\"}] + .")
          imageJson=$(echo "$imageJson" | jq ".rootfs.diff_ids |= [\"sha256:$layerChecksum\"] + .")
        done
        imageJsonChecksum=$(echo "$imageJson" | sha256sum | cut -d ' ' -f1)
        echo "$imageJson" > "image/$imageJsonChecksum.json"
        manifestJson=$(echo "$manifestJson" | jq ".[0].Config = \"$imageJsonChecksum.json\"")
        echo "$manifestJson" > image/manifest.json

        jshon -n object \
          -n object -s "$layerID" -i "$imageTag" \
          -i "$imageName" > image/repositories

        # Make the image read-only.
        chmod -R a-w image

        echo "Cooking the image..."
        tar -C image --hard-dereference --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --xform s:'./':: -c . | pigz -nT > $out

        echo "Finished."
      '';

    in
    result;

  # Build an image and populate its nix database with the provided
  # contents. The main purpose is to be able to use nix commands in
  # the container.
  # Be careful since this doesn't work well with multilayer.
  buildImageWithNixDb = args@{ contents ? null, extraCommands ? "", ... }:
    buildImage (args // {
      extraCommands = ''
        echo "Generating the nix database..."
        echo "Warning: only the database of the deepest Nix layer is loaded."
        echo "         If you want to use nix commands in the container, it would"
        echo "         be better to only have one layer that contains a nix store."
        # This requires Nix 1.12 or higher
        export NIX_REMOTE=local?root=$PWD
        ${nixUnstable}/bin/nix-store --load-db < ${nixRegistration contents}/db.dump

        # We fill the store in order to run the 'verify' command that
        # generates hash and size of output paths.
        # Note when Nix 1.12 is be the stable one, the database dump
        # generated by the exportReferencesGraph function will
        # contains sha and size. See
        # https://github.com/NixOS/nix/commit/c2b0d8749f7e77afc1c4b3e8dd36b7ee9720af4a
        storePaths=$(cat ${nixRegistration contents}/storePaths)
        echo "Copying everything to /nix/store (will take a while)..."
        cp -prd $storePaths nix/store/
        ${nixUnstable}/bin/nix-store --verify --check-contents

        mkdir -p nix/var/nix/gcroots/docker/
        for i in ${lib.concatStringsSep " " contents}; do
          ln -s $i nix/var/nix/gcroots/docker/$(basename $i)
        done;
      '' + extraCommands;
    });

  pathsFromGraphByPopularity = closure:
    runCommand "closure-paths"
    {
      exportReferencesGraph.graph = closure;
       __structuredAttrs = true;
       PATH = "${coreutils}/bin:${python3}/bin";
       builder = builtins.toFile "builder"
         ''
           . .attrs.sh
           python3 ${./closure-graph.py} .attrs.json graph > ''${outputs[out]}
         '';
    } "";
}
