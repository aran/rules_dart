"""A package record as a fetcher's repository makes one, for tests.

`DartPackageInfo(...)` states no `fetched_identity`; only a fetcher's
`fetched_package_metadata` does. Tests of records two fetchers supply build
theirs with `DartPackageInfo(...)` and give it one here.
"""

load("//dart/private:package_info.bzl", "purl_identity", "raw_dart_package_info")

def fetched(pkg, purl):
    """`pkg`, fetched as what `purl` names.

    Args:
      pkg: A `DartPackageInfo`.
      purl: The purl of what it was fetched as.

    Returns:
      A `DartPackageInfo`.
    """
    return raw_dart_package_info(
        label = pkg.label,
        package_name = pkg.package_name,
        package_root = pkg.package_root,
        version = pkg.version,
        language_version = pkg.language_version,
        code_assets = pkg.code_assets,
        data_assets = pkg.data_assets,
        unreplaced_hook = pkg.unreplaced_hook,
        link_hook = pkg.link_hook,
        link_hook_assets = pkg.link_hook_assets,
        linked_code_assets = pkg.linked_code_assets,
        license_file = pkg.license_file,
        metadata = pkg.metadata,
        fetched_identity = purl_identity(purl),
    )
