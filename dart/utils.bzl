"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
library root derivation, `package_config.json` generation, and source
co-location. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:common.bzl",
    _collect_packages = "collect_packages",
    _collect_transitive_resources = "collect_transitive_resources",
    _collect_transitive_srcs = "collect_transitive_srcs",
    _generate_dev_package_config = "generate_dev_package_config",
    _generate_package_config = "generate_package_config",
    _generate_package_config_content = "generate_package_config_content",
    _runfiles_path = "runfiles_path",
)
load(
    "//dart/private:dart_info.bzl",
    _dart_info = "dart_info",
    _dart_info_no_package = "dart_info_no_package",
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

# Build a `DartInfo` from what a target contributes itself, merging every
# dependency's closure internally. Any rule set that wraps Dart libraries should
# construct through this rather than calling `DartInfo(...)`: a field added to
# the provider is then a change here and nowhere else, and no caller can silence
# a missing field by declaring it empty and dropping its dependencies' values.
# Reading stays direct — `DartInfo` is indexed off targets as before.
dart_info = _dart_info

# The other constructor, for a target that ships no Dart package at all and
# provides `DartInfo` only to satisfy a `deps` attribute that requires one (a
# font-only target, a facade grouping other libraries). Takes `deps` and nothing
# else: with no package there is no `package_name`, no `lib_root`, no sources,
# and no code assets to declare, and the signature says so.
dart_info_no_package = _dart_info_no_package

collect_packages = _collect_packages

# Returns a depset[File]; pass it to action inputs / runfiles directly and
# flatten (once) only where per-file paths are inspected.
collect_transitive_srcs = _collect_transitive_srcs

# The sibling of [collect_transitive_srcs], for the non-Dart files a package
# ships in `lib/`. For consumers that stage a package whole — a bundler reading
# a dependency's files — rather than for producers, which get the same merge
# from [dart_info] without having to know the field exists.
collect_transitive_resources = _collect_transitive_resources

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
