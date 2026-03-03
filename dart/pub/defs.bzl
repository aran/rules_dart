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
