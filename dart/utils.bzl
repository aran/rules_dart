"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
library root derivation, `package_config.json` generation, and source
co-location. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:build_settings.bzl",
    _KERNEL_LIST_ATTR = "KERNEL_LIST_ATTR",
    _TRACK_CREATION_LOCATIONS_ATTR = "TRACK_CREATION_LOCATIONS_ATTR",
    _kernel_list = "kernel_list",
    _track_creation_locations = "track_creation_locations",
)
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
    _dart_analyzable_info_with_packages = "dart_analyzable_info_with_packages",
    _dart_info = "dart_info",
    _dart_info_no_package = "dart_info_no_package",
    _dart_package_info = "dart_package_info",
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
    _executable_defines = "executable_defines",
    _executable_defines_config = "executable_defines_config",
    _kernel_package_config = "kernel_package_config",
)
load(
    "//dart/private:exec_groups.bzl",
    _EXEC_TOOLS_TOOLCHAIN = "EXEC_TOOLS_TOOLCHAIN",
    _PORTABLE = "PORTABLE",
    _PORTABLE_EXEC_GROUPS = "PORTABLE_EXEC_GROUPS",
)
load(
    "//dart/private:runtime.bzl",
    _RUNTIME_INDEPENDENT_ATTR = "RUNTIME_INDEPENDENT_ATTR",
    _WEB_PLATFORM_SETTINGS = "WEB_PLATFORM_SETTINGS",
    _non_dart_transition = "non_dart_transition",
    _runtime_reset = "runtime_reset",
    _runtime_reset_when_independent = "runtime_reset_when_independent",
    _web_platform_config_settings = "web_platform_config_settings",
    _web_platform_settings = "web_platform_settings",
    _web_platform_transition = "web_platform_transition",
    _web_platforms_transition = "web_platforms_transition",
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
#
#     dart_info(
#         label = ctx.label,
#         packages = [dart_package_info(
#             label = ctx.label,
#             package_name = "foo",
#             lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
#             language_version = ctx.attr.language_version,
#         )],
#         deps = ctx.attr.deps,
#         srcs = ctx.files.srcs,
#     )
#
# `packages` holds one record for a library, or several for one target built
# over packages that depend on each other (pub allows it, Bazel does not).
dart_info = _dart_info

# The `DartPackageInfo` record of a package a target contributes, from what the
# rule states about it; checks that its code assets are namespaced to it.
dart_package_info = _dart_package_info

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

# The same wrapper for a target that contributes packages — a downstream test
# rule whose `srcs` are its package's `lib/` files plus an entrypoint outside
# them, or a library whose analysis closure adds dependencies its compile does
# not (`flutter_library`'s `sky_engine`). Routes the packages through
# [dart_info], so the target's own `package:<self>/…` imports resolve under the
# `dart_analyze` aspect rather than reporting `uri_does_not_exist`. The source
# split is the thing to get right: `srcs` stays the package-less entrypoint,
# `package_srcs` the packages' own files.
dart_analyzable_info_with_packages = _dart_analyzable_info_with_packages

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
# DartKernelSdkInfo target>)`, attaches it to its executable's `deps`,
# compiles the entrypoint with `dart_entry_kernel_action` and links with
# `dart_link_kernel_action`, merging `KERNEL_TOOL_ATTR` into its `attrs`.
#
# The executable and its modules compile in one environment, which is
# configuration: `executable_defines_config(implied_defines)`, made once at top
# level, gives the transition (`cfg`) its `deps` take and the `attrs` the rule
# merges to read the same configuration back. The environment is the rule's
# `defines`, then what `implied_defines(attr)` derives from its other
# attributes (a flavor, say), then its `_extra_dart_defines` flag, which names
# the flag its aspect reads. `dart_entry_kernel_action` reads it itself and
# fails if a dependency's modules were compiled in another; a compile the rule
# runs itself takes `executable_defines(ctx)`. `kernel_package_config` and
# `add_kernel_roots` address sources through the same `org-dartlang-root:///`
# roots the modules were compiled with.
#
# `--@rules_dart//dart:track_creation_locations` must be the same for the modules
# and the entrypoint: the aspect reads it itself, and a rule passes
# `track_creation_locations(ctx)` to `dart_entry_kernel_action`, merging
# `TRACK_CREATION_LOCATIONS_ATTR` into its `attrs`.
#
# A test's program is a kernel list unless `--@rules_dart//dart:kernel_list`
# is off: a rule passes `kernel_list = kernel_list(ctx)` to
# `dart_link_kernel_action`, merging `KERNEL_LIST_ATTR` into its `attrs`, adds
# the files it returns to the runfiles, and has its launcher read the list with
# `@rules_dart//dart/kernel_list` (or join it, for a runner that takes one file).
#
# Those compiles, and the import checks below, run in the `PORTABLE` execution
# group, on any host with a Dart SDK (`EXEC_TOOLS_TOOLCHAIN`), and the kernel
# tool is built for that host: a rule merging `KERNEL_TOOL_ATTR` declares
# `exec_groups = PORTABLE_EXEC_GROUPS`, or its own `PORTABLE` group naming
# `EXEC_TOOLS_TOOLCHAIN` and any toolchains more. `dart_module_aspect`'s
# `exec_toolchains` adds those to the aspect's.
dart_module_aspect = _dart_module_aspect
executable_defines_config = _executable_defines_config
executable_defines = _executable_defines
collect_modules = _collect_modules
dart_entry_kernel_action = _dart_entry_kernel_action
dart_link_kernel_action = _dart_link_kernel_action
kernel_package_config = _kernel_package_config
add_kernel_roots = _add_kernel_roots
KERNEL_TOOL_ATTR = _KERNEL_TOOL_ATTR
KERNEL_LIST_ATTR = _KERNEL_LIST_ATTR
kernel_list = _kernel_list
TRACK_CREATION_LOCATIONS_ATTR = _TRACK_CREATION_LOCATIONS_ATTR
track_creation_locations = _track_creation_locations
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

# The runtime, a constraint of the target platform
# (`@rules_dart//dart/constraints:runtime`: `vm`, `js`, `wasm`), and
# `--@rules_dart//dart:track_creation_locations` change what Dart compiles to,
# and an executable's environment declarations what its modules compile to.
# A rule nothing of which is compiled Dart — a native library, a code
# generator, a data asset, a module built by another language's toolchain —
# takes `cfg = non_dart_transition`, which resets all three, so every route into
# it, from a web binary or a test tracking creation locations or with its own
# `defines` or none of these, reaches one configured target, built once. A Dart
# library must keep `track_creation_locations` and the environment, since its
# kernel modules are compiled in its own configuration and must match every
# other module of the program. One that is
# the same under every web compiler (a pub package) takes
# `cfg = runtime_reset`, which resets the runtime alone. A rule some
# of whose targets are compiler-independent and some not (one that wraps both
# pub packages and first-party code) merges `RUNTIME_INDEPENDENT_ATTR`
# into its `attrs` and takes `cfg = runtime_reset_when_independent`, which
# resets the runtime of the targets that set
# `runtime_independent = True`, as `dart_library` does.
non_dart_transition = _non_dart_transition
runtime_reset = _runtime_reset
runtime_reset_when_independent = _runtime_reset_when_independent
RUNTIME_INDEPENDENT_ATTR = _RUNTIME_INDEPENDENT_ATTR

# A rule that builds Dart code for a web platform does it with these, never by
# setting `--platforms` itself: they record the platforms the build had, which
# is what lets the resets above rejoin that configuration. `cfg =
# web_platform_transition` on an attribute builds it for the platform in the
# rule's `platform` attribute; `web_platforms_transition` builds it once per
# platform in the rule's `web_platforms` (a split, keyed by platform label).
web_platform_transition = _web_platform_transition
web_platforms_transition = _web_platforms_transition

# A rule set whose branches are computed from more than a list of platforms
# (from `compilation_mode` too, say) writes its own transition with
# `WEB_PLATFORM_SETTINGS` among its `inputs` and `outputs`, and returns
# `web_platform_settings(settings, platform)` for each branch.
WEB_PLATFORM_SETTINGS = _WEB_PLATFORM_SETTINGS
web_platform_settings = _web_platform_settings

# An analysis test, whose `config_settings` is a fixed dict rather than a
# transition, configures its target under test as a web binary's `deps` with
# `web_platform_config_settings(platform)`, merging any settings of its own:
#
#     analysistest.make(
#         _impl,
#         config_settings = web_platform_config_settings(
#             Label("@rules_dart//dart/platforms:wasm"),
#         ) | {"//command_line_option:compilation_mode": "opt"},
#     )
#
# It records the platforms the build had, as the transitions do, so a reset
# beneath the target goes back to them, as it would from a real web binary.
# Those are the host's unless the tests run under another `--platforms`; then
# pass them as `platforms`.
web_platform_config_settings = _web_platform_config_settings
