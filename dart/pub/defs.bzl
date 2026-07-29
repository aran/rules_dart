"""Pub.dev package management.

This file is reserved for future pub-related build rules. To declare pub
dependencies, use the module extension in your MODULE.bazel instead:

    pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")

    # Individual packages:
    pub.package(name = "path", version = "1.9.1", sha256 = "...")
    use_repo(pub, "path")

    # Or from a lockfile:
    pub.from_lock(name = "my_deps", lock = "//:pubspec.lock")
    use_repo(pub, "my_deps")
"""

load("//dart/pub/private:version.bzl", _parse_semver = "parse_semver")

# Re-exported for consumers outside //dart/pub — `//dart/ext/registry.bzl`
# version-bounds its curated code-asset entries. Loading the private bzl
# directly would trip buildifier's bzl-visibility check, so it is exposed
# here, the same way `pub_lock_package.bzl` exposes `derive_language_version`.
parse_semver = _parse_semver
