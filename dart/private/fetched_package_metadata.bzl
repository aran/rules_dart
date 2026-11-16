"""The package declarations of the BUILD files a fetcher's repository generates.

Loadable from any repository, because the BUILD files that load them are
generated into repositories of their own; they are still not part of the API a
workspace states its packages with, and a target of the main repository fails.
`make_package_metadata_content(source = ...)` writes the target, and
`pub_package_identity(source).loads` its load.
"""

load(
    "//dart/private:dart_package_metadata.bzl",
    _fetched_local_git_package_metadata = "fetched_local_git_package_metadata",
    _fetched_package_metadata = "fetched_package_metadata",
    _fetched_path_package_metadata = "fetched_path_package_metadata",
)

visibility("public")

fetched_package_metadata = _fetched_package_metadata
fetched_local_git_package_metadata = _fetched_local_git_package_metadata
fetched_path_package_metadata = _fetched_path_package_metadata
