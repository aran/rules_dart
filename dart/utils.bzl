"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
library root derivation, `package_config.json` generation, and source
co-location. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:common.bzl",
    _PATH_MAPPING = "PATH_MAPPING",
    _add_kernel_roots = "add_kernel_roots",
    _code_asset_identity = "code_asset_identity",
    _collect_packages = "collect_packages",
    _collect_transitive_code_assets = "collect_transitive_code_assets",
    _collect_transitive_resources = "collect_transitive_resources",
    _collect_transitive_srcs = "collect_transitive_srcs",
    _generate_dev_package_config = "generate_dev_package_config",
    _generate_package_config = "generate_package_config",
    _generate_package_config_content = "generate_package_config_content",
    _package_code_assets = "package_code_assets",
    _resolve_code_assets = "resolve_code_assets",
    _runfiles_path = "runfiles_path",
)
load("//dart/private:dart_deps.bzl", _DART_TOOLCHAIN_TYPES_ATTR = "DART_TOOLCHAIN_TYPES_ATTR")
load(
    "//dart/private:dart_import_check.bzl",
    _dart_import_check_aspect = "dart_import_check_aspect",
    _import_check_validation = "import_check_validation",
)
load(
    "//dart/private:dart_info.bzl",
    _dart_analyzable_info = "dart_analyzable_info",
    _dart_analyzable_info_with_package = "dart_analyzable_info_with_package",
    _dart_info = "dart_info",
    _dart_info_no_package = "dart_info_no_package",
)
load(
    "//dart/private:dart_library.bzl",
    _derive_lib_root = "derive_lib_root",
    _derive_package_name = "derive_package_name",
)
load(
    "//dart/private:dart_link_hook.bzl",
    _dart_link_hook_actions = "dart_link_hook_actions",
    _link_hook_runner_attr = "link_hook_runner_attr",
    _parse_data_asset_ids = "parse_data_asset_ids",
)
load(
    "//dart/private:dart_module.bzl",
    _KERNEL_TOOL_ATTR = "KERNEL_TOOL_ATTR",
    _collect_modules = "collect_modules",
    _dart_entry_kernel_action = "dart_entry_kernel_action",
    _dart_link_kernel_action = "dart_link_kernel_action",
    _dart_module_aspect = "dart_module_aspect",
    _kernel_package_config = "kernel_package_config",
    _module_defines_transition = "module_defines_transition",
)
load(
    "//dart/private:exec_groups.bzl",
    _EXEC_TOOLS_TOOLCHAIN = "EXEC_TOOLS_TOOLCHAIN",
    _PORTABLE = "PORTABLE",
    _PORTABLE_EXEC_GROUPS = "PORTABLE_EXEC_GROUPS",
)
load(
    "//dart/private:source_set.bzl",
    _COPY_TO_DIRECTORY_TOOLCHAINS = "COPY_TO_DIRECTORY_TOOLCHAINS",
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

# For an executable rule — a binary, a test — whose entrypoint belongs to no
# package's `lib/` and so can appear in no `DartInfo`. Returns the wrapper
# the `dart_analyze` aspect and `dart_fix` read, nesting a `dart_info_no_package()`
# closure beside those sources. Deliberately not what an executable returns for
# `deps` to see: `deps` requires `DartInfo`, and a binary is not a dependency.
dart_analyzable_info = _dart_analyzable_info

# The same wrapper for an executable that *also* contributes a package — a
# downstream test rule whose `srcs` are its package's `lib/` files plus an
# entrypoint outside them. Routes the package through [dart_info], so the
# target's own `package:<self>/…` imports resolve under the `dart_analyze`
# aspect rather than reporting `uri_does_not_exist`. The source split is the
# thing to get right: `srcs` stays the package-less entrypoint, `package_srcs`
# the package's own files.
dart_analyzable_info_with_package = _dart_analyzable_info_with_package

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

# Code asset resolution, as `dart_binary` and `dart_test` do it, for a rule set
# that stages a program's native libraries itself. `resolve_code_assets` unions
# what `collect_transitive_code_assets` reaches with a target's own
# `code_assets`, one asset per id, and fails on two definitions of one id as
# `code_asset_identity` tells them apart. `package_code_assets` reads one
# `DartPackageInfo`'s assets.
code_asset_identity = _code_asset_identity
collect_transitive_code_assets = _collect_transitive_code_assets
package_code_assets = _package_code_assets
resolve_code_assets = _resolve_code_assets

# The execution requirements of an action that may run once for every
# configuration building the same thing (`--experimental_output_paths=strip`):
# add them to an action whose arguments reach output paths only through Files
# (`Args.add`, `add_all`, `map_each`) and whose generated inputs name none.
PATH_MAPPING = _PATH_MAPPING
derive_lib_root = _derive_lib_root
derive_package_name = _derive_package_name

# Source co-location: assemble a package whose hand-written and generated files
# straddle the source tree and `bazel-out` into one tree-artifact directory, so
# `part` directives and a single `rootUri` resolve at compile time. Any rule
# calling `colocate_packages` must declare
# `COPY_TO_DIRECTORY_TOOLCHAINS` in its `toolchains`.
colocate_packages = _colocate_packages
COPY_TO_DIRECTORY_TOOLCHAINS = _COPY_TO_DIRECTORY_TOOLCHAINS

# Run link hooks from inside another rule, for one that compiles its own kernel
# and so cannot depend on a `dart_link_hook` target without a cycle. The hooks
# run in `PORTABLE`: the rule declares `PORTABLE_EXEC_GROUPS` and merges
# `link_hook_runner_attr()` into its `attrs`.
dart_link_hook_actions = _dart_link_hook_actions
link_hook_runner_attr = _link_hook_runner_attr
parse_data_asset_ids = _parse_data_asset_ids

# Per-library kernel compilation (see `dart_module.bzl`). A rule set with its own
# platform makes its aspect once at top level, `dart_module_aspect(<label of a
# DartKernelSdkInfo target>)`, attaches it to its executable's `deps` with
# `cfg = module_defines_transition` (the executable's `defines` reach its
# modules), compiles the entrypoint with `dart_entry_kernel_action` and links
# with `dart_link_kernel_action`, merging
# `KERNEL_TOOL_ATTR` into its `attrs`. `kernel_package_config` and
# `add_kernel_roots` address sources through the same `org-dartlang-root:///`
# roots the modules were compiled with.
#
# Those compiles, and the import checks below, run in the `PORTABLE` execution
# group, on any host with a Dart SDK (`EXEC_TOOLS_TOOLCHAIN`), and the kernel
# tool is built for that host: a rule merging `KERNEL_TOOL_ATTR` declares
# `exec_groups = PORTABLE_EXEC_GROUPS`, or its own `PORTABLE` group naming
# `EXEC_TOOLS_TOOLCHAIN` and any toolchains more. `dart_module_aspect`'s
# `exec_toolchains` adds those to the aspect's.
dart_module_aspect = _dart_module_aspect
module_defines_transition = _module_defines_transition
collect_modules = _collect_modules
dart_entry_kernel_action = _dart_entry_kernel_action
dart_link_kernel_action = _dart_link_kernel_action
kernel_package_config = _kernel_package_config
add_kernel_roots = _add_kernel_roots
KERNEL_TOOL_ATTR = _KERNEL_TOOL_ATTR
PORTABLE = _PORTABLE
PORTABLE_EXEC_GROUPS = _PORTABLE_EXEC_GROUPS
EXEC_TOOLS_TOOLCHAIN = _EXEC_TOOLS_TOOLCHAIN

# A rule whose `DartInfo` dependencies come from a toolchain names the toolchain
# types in a private `label_list` of this name, so the kernel module aspect
# reaches them: `DART_TOOLCHAIN_TYPES_ATTR: attr.label_list(default = [...])`.
DART_TOOLCHAIN_TYPES_ATTR = _DART_TOOLCHAIN_TYPES_ATTR

# Import checks (strict deps, files of the target's own package, layering) as
# validation actions. An executable rule attaches `dart_import_check_aspect` to
# its `deps` and returns `OutputGroupInfo(_validation =
# import_check_validation(ctx, ctx.executable._kernel_tool, own_srcs,
# own_package, ctx.attr.deps))`, merging `KERNEL_TOOL_ATTR` into its `attrs`.
dart_import_check_aspect = _dart_import_check_aspect
import_check_validation = _import_check_validation
