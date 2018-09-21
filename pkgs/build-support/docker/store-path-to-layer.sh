#!/bin/sh

tarsum=$1
shift
layerNumber=$1
shift

layerPath="./layers/$layerNumber"
echo "Creating layer #$layerNumber for $@"

mkdir -p "$layerPath"
tar -rpf "$layerPath/layer.tar" --hard-dereference --sort=name \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 "$@"

# Compute a checksum of the tarball.
tarsum=$($tarsum < $layerPath/layer.tar)

# Add a 'checksum' field to the JSON, with the value set to the
# checksum of the tarball.
cat ./generic.json | jshon -s "$tarsum" -i checksum > $layerPath/json

# Indicate to docker that we're using schema version 1.0.
echo -n "1.0" > $layerPath/VERSION
