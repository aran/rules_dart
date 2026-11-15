"""The names by which a source repository finds and loads its files repository.

No loads: a files repository's rule loads this, and each `.bzl` it loads is
part of the cache key of every package's files.
"""

visibility(["//dart/pub/..."])

# The file every files repository has, by which a source repository finds it.
FILES_MARKER = "BUILD.bazel"

# The file a source repository's BUILD file loads from its files repository,
# so that Bazel makes the files repository before reading through the links.
# Fetching the source repository does that too, but a vendored one is never
# fetched, and its links would then dangle while its globs run.
FILES_LOAD = "pub_files.bzl"
