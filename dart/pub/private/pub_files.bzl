"""Repositories holding a fetched pub package's files, and nothing generated.

A package's source repository (`pub_lock_package`, rules_flutter's
`flutter_pub_package`) generates its build from rules_dart's Starlark, so its
cache key changes with every edit to that Starlark, and with every rules_dart
version. Were the package's files stored in it, Bazel's repository contents
cache would keep another copy of every package for each. So the files are
fetched into a repository of their own, defined here with only the fetching
code loaded, whose cache key changes only with what is fetched. The source
repository links them in with `link_pub_files`.

Keep this file's loads to the fetching code: each `.bzl` it loads is part of
the key of every package's files.
"""

load("//dart/pub:pub_files_root.bzl", "write_pub_files_root")
load("//dart/pub/private:pub_archive.bzl", "fetch_pub_archive")
load("//dart/pub/private:pub_files_names.bzl", _FILES_LOAD = "FILES_LOAD", _FILES_MARKER = "FILES_MARKER")
load("//dart/pub/private:pub_git.bzl", "fetch_pub_git")

visibility("//dart/...")

FILES_LOAD = _FILES_LOAD
FILES_MARKER = _FILES_MARKER

def _finish(rctx):
    write_pub_files_root(rctx)
    return rctx.repo_metadata(reproducible = True)

def _pub_archive_files_impl(rctx):
    fetch_pub_archive(
        rctx,
        package_name = rctx.attr.package_name,
        version = rctx.attr.version,
        sha256 = rctx.attr.sha256,
        base_url = rctx.attr.base_url,
    )
    return _finish(rctx)

pub_archive_files = repository_rule(
    implementation = _pub_archive_files_impl,
    attrs = {
        "package_name": attr.string(doc = "The pub package name.", mandatory = True),
        "version": attr.string(doc = "The package version, as pubspec.lock records it.", mandatory = True),
        "sha256": attr.string(doc = "SHA256 hash of the package archive, as pubspec.lock records it.", mandatory = True),
        "base_url": attr.string(doc = "Base URL for the pub repository.", default = "https://pub.dev"),
    },
    doc = "Fetches a hosted pub package's files, for a source repository to link in with `link_pub_files`.",
)

def _pub_git_files_impl(rctx):
    fetch_pub_git(
        rctx,
        package_name = rctx.attr.package_name,
        version = rctx.attr.version,
        url = rctx.attr.url,
        resolved_ref = rctx.attr.resolved_ref,
        path = rctx.attr.path,
        lock = rctx.attr.lock,
    )
    return _finish(rctx)

pub_git_files = repository_rule(
    implementation = _pub_git_files_impl,
    attrs = {
        "package_name": attr.string(doc = "The pub package name.", mandatory = True),
        "version": attr.string(doc = "The package version, as pubspec.lock records it.", mandatory = True),
        "url": attr.string(doc = "The repository, as pubspec.lock's `description.url` records it.", mandatory = True),
        "resolved_ref": attr.string(doc = "The locked commit: `description.resolved-ref`, a full commit id.", mandatory = True),
        "path": attr.string(doc = "The package's directory in the repository: `description.path`.", default = "."),
        "lock": attr.label(
            doc = "The lock, against whose directory a relative `url` is resolved, " +
                  "as pub resolves it. Set only for a relative `url`.",
            allow_single_file = True,
        ),
    },
    doc = "Fetches a git pub package's files at its locked commit, for a source repository to link in with `link_pub_files`.",
)

def pub_files_label(repo):
    """The label a source repository's `files` attribute names a files repository by.

    Args:
        repo: The files repository's name, as the module extension declares it.

    Returns:
        The label, as a string.
    """
    return "@{}//:{}".format(repo, FILES_MARKER)
