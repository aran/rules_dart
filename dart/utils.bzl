"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
library root derivation, `package_config.json` generation, and source
co-location. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:common.bzl",
    _collect_packages = "collect_packages",
    _collect_transitive_srcs = "collect_transitive_srcs",
    _generate_dev_package_config = "generate_dev_package_config",
    _generate_package_config = "generate_package_config",
    _generate_package_config_content = "generate_package_config_content",
    _runfiles_path = "runfiles_path",
)
load(
    "//dart/private:dart_library.bzl",
    _derive_lib_root = "derive_lib_root",
    _derive_package_name = "derive_package_name",
)
load(
    "//dart/private:source_set.bzl",
    _COPY_TO_DIRECTORY_TOOLCHAINS = "COPY_TO_DIRECTORY_TOOLCHAINS",
    _colocate_entrypoint = "colocate_entrypoint",
    _colocate_packages = "colocate_packages",
)

collect_packages = _collect_packages
collect_transitive_srcs = _collect_transitive_srcs

# The exec-root-relative package_config generator: resolves each package's
# actual exec-root location from its source Files and computes `rootUri` as a
# path relative to the config file. (Distinct from `generate_package_config_content`,
# which is the simpler prefix-based variant for static staging-directory layouts.)
generate_package_config = _generate_package_config

# Hot-reload variant of the above: emits `<scheme>:///` rootUris for packages
# whose sources straddle the tree and `bazel-out` (codegen), plus the filesystem
# roots the frontend_server must search so live source edits and generated files
# both resolve. See `generate_dev_package_config` for the returned struct.
generate_dev_package_config = _generate_dev_package_config
generate_package_config_content = _generate_package_config_content
runfiles_path = _runfiles_path
derive_lib_root = _derive_lib_root
derive_package_name = _derive_package_name

# Source co-location: assemble a package whose hand-written and generated files
# straddle the source tree and `bazel-out` into one tree-artifact directory, so
# `part` directives and a single `rootUri` resolve at compile time. Any rule
# calling `colocate_packages`/`colocate_entrypoint` must declare
# `COPY_TO_DIRECTORY_TOOLCHAINS` in its `toolchains`.
colocate_packages = _colocate_packages
colocate_entrypoint = _colocate_entrypoint
COPY_TO_DIRECTORY_TOOLCHAINS = _COPY_TO_DIRECTORY_TOOLCHAINS
