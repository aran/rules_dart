"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
and library root derivation. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:common.bzl",
    _collect_packages = "collect_packages",
    _collect_transitive_srcs = "collect_transitive_srcs",
    _generate_package_config_content = "generate_package_config_content",
    _runfiles_path = "runfiles_path",
)
load(
    "//dart/private:dart_library.bzl",
    _derive_lib_root = "derive_lib_root",
    _derive_package_name = "derive_package_name",
)

collect_packages = _collect_packages
collect_transitive_srcs = _collect_transitive_srcs
generate_package_config_content = _generate_package_config_content
runfiles_path = _runfiles_path
derive_lib_root = _derive_lib_root
derive_package_name = _derive_package_name
