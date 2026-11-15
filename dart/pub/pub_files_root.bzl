"""For a repository rule that fetches a pub package's files itself.

A source repository links a files repository in with `link_pub_files` from
`pub_lock_package.bzl`. rules_dart's own files repositories are made by
`pub.from_lock()`; a rule set that fetches a package's files from elsewhere
calls `write_pub_files_root` once its files are in place.

Load nothing heavier than this file into such a rule: each `.bzl` it loads is
part of the cache key of every package's files.
"""

load("//dart/pub/private:pub_files_names.bzl", "FILES_LOAD", "FILES_MARKER")

def write_pub_files_root(rctx):
    """Writes what a files repository has at its root besides the package's files.

    Call it after the files are fetched: it writes over any `BUILD.bazel` the
    package ships, so the root is a package with nothing in it, and writes the
    file whose load `link_pub_files` returns.

    Args:
        rctx: The files repository's `repository_ctx`.
    """
    rctx.file(FILES_MARKER, "")
    rctx.file(FILES_LOAD, "FILES = True\n")
