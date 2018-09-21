
import json
import sys
from pprint import pprint
from collections import defaultdict

# Find paths in the original dataset which are never referenced by
# any other paths
def find_roots(closures):
    roots = [];

    for closure in closures:
        path = closure['path']
        if not any_refer_to(path, closures):
            roots.append(path)

    return roots

def any_refer_to(path, closures):
    for closure in closures:
        if path != closure['path']:
            if path in closure['references']:
                return True
    return False

def all_paths(closures):
    paths = []
    for closure in closures:
        paths.append(closure['path'])
        paths.extend(closure['references'])
    paths.sort()
    return list(set(paths))

# Convert:
#
# [
#    { path: /nix/store/foo, references: [ /nix/store/foo, /nix/store/bar, /nix/store/baz ] },
#    { path: /nix/store/bar, references: [ /nix/store/bar, /nix/store/baz ] },
#    { path: /nix/store/baz, references: [ /nix/store/baz, /nix/store/tux ] },
#    { path: /nix/store/tux, references: [ /nix/store/tux ] }
#  ]
#
# To:
#    {
#      /nix/store/foo: [ /nix/store/bar, /nix/store/baz ],
#      /nix/store/bar: [ /nix/store/baz ],
#      /nix/store/baz: [ /nix/store/tux ] },
#      /nix/store/tux: [ ]
#    }
#
# Note that it drops self-references to avoid loops.
def make_lookup(closures):
    lookup = {}

    for closure in closures:
        # paths often self-refer
        nonreferential_paths = [ref for ref in closure['references'] if ref != closure['path']]
        lookup[closure['path']] = nonreferential_paths

    return lookup

# Convert:
#
# /nix/store/foo with
#  {
#    /nix/store/foo: [ /nix/store/bar, /nix/store/baz ],
#    /nix/store/bar: [ /nix/store/baz ],
#    /nix/store/baz: [ /nix/store/tux ] },
#    /nix/store/tux: [ ]
#  }
#
# To:
#
# {
#    /nix/store/foo: {
#                      /nix/store/bar: {
#                                        /nix/store/baz: {
#                                                           /nix/store/tux: {}
#                                        }
#                      }
#                      /nix/store/baz: {
#                                         /nix/store/tux: {}
#                      }
#    }
# }
def make_graph_segment_from_root(root, lookup):
    children = {}
    for ref in lookup[root]:
        children[ref] = make_graph_segment_from_root(ref, lookup)
    return children

# Convert a graph segment in to a popularity-counted dictionary:
#
# From:
# {
#    /nix/store/foo: {
#                      /nix/store/bar: {
#                                        /nix/store/baz: {
#                                                           /nix/store/tux: {}
#                                        }
#                      }
#                      /nix/store/baz: {
#                                         /nix/store/tux: {}
#                      }
#    }
# }
#
# to:
# [
#   /nix/store/foo: 1
#   /nix/store/bar: 1
#   /nix/store/baz: 2
#   /nix/store/tux: 2
# ]
def graph_popularity_contest(full_graph):
    popularity = defaultdict(int)
    for path, subgraph in full_graph.items():
        popularity[path] += 1
        for subpath, subpopularity in graph_popularity_contest(subgraph).items():
            popularity[subpath] += subpopularity

    return popularity

# Emit a list of packages by popularity, most first:
#
# From:
# [
#   /nix/store/foo: 1
#   /nix/store/bar: 1
#   /nix/store/baz: 2
#   /nix/store/tux: 2
# ]
#
# To:
# [ /nix/store/baz /nix/store/tux /nix/store/bar /nix/store/foo ]
def order_by_popularity(paths):
    paths_by_popularity = defaultdict(list)
    popularities = []
    for path, popularity in paths.items():
        popularities.append(popularity)
        paths_by_popularity[popularity].append(path)

    popularities = list(set(popularities))
    popularities.sort()

    flat_ordered = []
    for popularity in popularities:
        paths = paths_by_popularity[popularity]
        paths.sort(key=package_name)

        flat_ordered.extend(reversed(paths))
    return list(reversed(flat_ordered))

def package_name(path):
    parts = path.split('-')
    start = parts.pop(0)
    # don't throw away any data, so the order is always the same.
    # even in cases where only the hash at the start has changed.
    parts.append(start)
    return '-'.join(parts)

def main():
    filename = sys.argv[1]
    key = sys.argv[2]

    with open(filename) as f:
        data = json.load(f)

    # Data comes in as:
    # [
    #    { path: /nix/store/foo, references: [ /nix/store/foo, /nix/store/bar, /nix/store/baz ] },
    #    { path: /nix/store/bar, references: [ /nix/store/bar, /nix/store/baz ] },
    #    { path: /nix/store/baz, references: [ /nix/store/baz, /nix/store/tux ] },
    #    { path: /nix/store/tux, references: [ /nix/store/tux ] }
    #  ]
    #
    # and we want to get out a list of paths ordered by how universally,
    # important they are, ie: tux is referenced by every path, transitively
    # so it should be #1
    #
    # [
    #   /nix/store/tux,
    #   /nix/store/baz,
    #   /nix/store/bar,
    #   /nix/store/foo,
    # ]
    graph = data[key]

    roots = find_roots(graph);
    lookup = make_lookup(graph)

    full_graph = {}
    for root in roots:
        full_graph[root] = make_graph_segment_from_root(root, lookup)

    ordered = order_by_popularity(graph_popularity_contest(full_graph))
    missing = []
    for path in all_paths(graph):
        if path not in ordered:
            missing.append(path)

    ordered.extend(missing)
    print("\n".join(ordered))

main()
