"""Public utility functions for Dart rules.

Re-exports commonly needed helpers for package resolution, source collection,
package root derivation, `package_config.json` generation, and source
co-location. These are used by both rules_dart and rules_flutter.
"""

load(
    "//dart/private:build_settings.bzl",
    _KERNEL_LIST_ATTR = "KERNEL_LIST_ATTR",
    _MODULAR_KERNEL_ATTR = "MODULAR_KERNEL_ATTR",
    _SPLIT_DEBUG_INFO_ATTR = "SPLIT_DEBUG_INFO_ATTR",
    _TRACK_CREATION_LOCATIONS_ATTR = "TRACK_CREATION_LOCATIONS_ATTR",
    _kernel_list = "kernel_list",
    _modular_kernel = "modular_kernel",
    _split_debug_info = "split_debug_info",
    _track_creation_locations = "track_creation_locations",
)
load(
    "//dart/private:common.bzl",
    _EMPTY_PACKAGE_CONFIG_ATTR = "EMPTY_PACKAGE_CONFIG_ATTR",
    _PATH_MAPPING = "PATH_MAPPING",
    _add_kernel_roots = "add_kernel_roots",
    _collect_packages = "collect_packages",
    _collect_transitive_resources = "collect_transitive_resources",
    _collect_transitive_runfiles = "collect_transitive_runfiles",
    _collect_transitive_srcs = "collect_transitive_srcs",
    _derive_package_name = "derive_package_name",
    _empty_package_config = "empty_package_config",
    _executable_package_record = "executable_package_record",
    _generate_dev_package_config = "generate_dev_package_config",
    _generate_package_config = "generate_package_config",
    _generate_package_config_content = "generate_package_config_content",
    _merged_package_record = "merged_package_record",
    _package_code_assets = "package_code_assets",
    _package_data_assets = "package_data_assets",
    _package_identity_attrs = "package_identity_attrs",
    _package_license_file = "package_license_file",
    _program_packages = "program_packages",
    _resolve_package_identity = "resolve_package_identity",
    _runfiles_path = "runfiles_path",
)
load("//dart/private:dart_compile.bzl", _dart_compile_action = "dart_compile_action")
load(
    "//dart/private:dart_coverage.bzl",
    _COVERAGE_ATTRS = "COVERAGE_ATTRS",
    _test_coverage = "test_coverage",
)
load("//dart/private:dart_deps.bzl", _DART_TOOLCHAIN_TYPES_ATTR = "DART_TOOLCHAIN_TYPES_ATTR")
load(
    "//dart/private:dart_import_check.bzl",
    _LIBRARY_IMPORT_CHECKER_ATTRS = "LIBRARY_IMPORT_CHECKER_ATTRS",
    _dart_import_check_aspect = "dart_import_check_aspect",
    _import_check_output_groups = "import_check_output_groups",
    _library_import_check = "library_import_check",
)
load(
    "//dart/private:dart_info.bzl",
    _dart_analyzable_info = "dart_analyzable_info",
    _dart_analyzable_info_no_package = "dart_analyzable_info_no_package",
    _dart_info_no_package = "dart_info_no_package",
    _package_info_from_metadata = "package_info_from_metadata",
    _package_lib_prefix = "package_lib_prefix",
)
load("//dart/private:dart_library.bzl", _library_package = "library_package")
load(
    "//dart/private:dart_module.bzl",
    _KERNEL_TOOL_ATTR = "KERNEL_TOOL_ATTR",
    _collect_modules = "collect_modules",
    _dart_entry_kernel_action = "dart_entry_kernel_action",
    _dart_kernel_runtime = "dart_kernel_runtime",
    _dart_link_kernel_action = "dart_link_kernel_action",
    _dart_module_aspect = "dart_module_aspect",
    _dart_whole_program_kernel_action = "dart_whole_program_kernel_action",
    _executable_defines = "executable_defines",
    _executable_defines_config = "executable_defines_config",
    _kernel_package_config = "kernel_package_config",
)
load("//dart/private:dart_summary.bzl", _SUMMARY_ATTRS = "SUMMARY_ATTRS", _dart_info = "dart_info")
load(
    "//dart/private:exec_groups.bzl",
    _EXEC_TOOLS_TOOLCHAIN = "EXEC_TOOLS_TOOLCHAIN",
    _PORTABLE = "PORTABLE",
    _PORTABLE_EXEC_GROUPS = "PORTABLE_EXEC_GROUPS",
)
load("//dart/private:package_info.bzl", _parse_data_asset_ids = "parse_data_asset_ids")
load("//dart/private:package_root.bzl", _derive_package_root = "derive_package_root")
load(
    "//dart/private:program_assets.bzl",
    _PROGRAM_ASSETS_TOOLCHAINS = "PROGRAM_ASSETS_TOOLCHAINS",
    _dart_program_assets_actions = "dart_program_assets_actions",
    _program_asset_file = "program_asset_file",
    _program_assets_action_args = "program_assets_action_args",
    _program_assets_attrs = "program_assets_attrs",
    _program_kernel_code_assets = "program_kernel_code_assets",
    _vm_code_config = "vm_code_config",
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
#     package = library_package(ctx, ctx.files.srcs, ctx.files.resources)
#     dart_info(
#         ctx = ctx,
#         packages = [package.record],
#         deps = ctx.attr.deps,
#         srcs = ctx.files.srcs,
#         resources = ctx.files.resources,
#     )
#
# `packages` holds one record for a library, or several for one target built
# over packages that depend on each other (pub allows it, Bazel does not).
dart_info = _dart_info

# What a rule building `DartInfo` with `dart_info()` merges into its `attrs`,
# beside `exec_groups = PORTABLE_EXEC_GROUPS` and `COPY_TO_DIRECTORY_TOOLCHAINS`
# among its `toolchains`: `dart_info()` declares the library's analyzer
# summary, which analysis against summaries reads and nothing else builds.
SUMMARY_ATTRS = _SUMMARY_ATTRS

# The package a target is part of, declared as rules_dart's rules declare it. A
# rule merges `package_identity_attrs()` (the `package` attribute, a
# `dart_package_metadata`) into its `attrs`, so a package built by targets of
# several rule sets names one declaration on each. It takes `mandatory` for a
# rule that cannot do without one, and `doc` for the rule's own words:
#
#     attrs = {...} | package_identity_attrs(
#         mandatory = True,
#         doc = "The package this application is, ...",
#     )
#
# `library_package(ctx, srcs, resources)` is what a library rule does with it:
# it resolves the declaration, checks that the target's files sit under the
# package's `lib/` and collide with none (a library naming a declaration in
# another directory fails, naming the file), and returns
# `struct(record, metadata, package_name, package_root, language_version)`:
# the target's `DartPackageInfo`, for `dart_info(packages = [package.record])`,
# and what it came from. A target naming no declaration is named after its
# root's directory and states nothing else.
#
# For a rule whose sources are not files to check (an executable, which belongs
# to its package wherever its BUILD file is), `resolve_package_identity(ctx)`
# returns the declaration as
# `struct(metadata, package_name, language_version, package_root, license_file)`,
# and `executable_package_record(ctx.label, identity)` the target's
# `DartPackageInfo`, rooted at `package_root`: the declaration's package root,
# or the BUILD file's when none is named (`metadata` is `None`, and the name its
# directory's). A target that takes its declaration from elsewhere (a test built
# in its application's package) passes it: `resolve_package_identity(ctx,
# metadata = application[DartPackageMetadataInfo])`; if the target also names
# `package`, it must be the same one. Both are what `merged_package_record`
# below takes.
package_identity_attrs = _package_identity_attrs
library_package = _library_package
resolve_package_identity = _resolve_package_identity
executable_package_record = _executable_package_record

# The `DartPackageInfo` record of a target that names a `dart_package_metadata`
# (its `DartPackageMetadataInfo`), rooted where the target's sources are. Every
# fact comes from the declaration.
package_info_from_metadata = _package_info_from_metadata

# The other constructor, for a target that ships no Dart package at all and
# provides `DartInfo` only to satisfy a `deps` attribute that requires one (a
# font-only target, a facade grouping other libraries). Takes `deps` and nothing
# else: with no package there is no `package_name`, no `package_root`, no sources,
# and no code assets to declare, and the signature says so.
dart_info_no_package = _dart_info_no_package

# For an executable rule — a binary, a test — that also contributes packages: a
# downstream test rule whose `srcs` are its package's `lib/` files plus an
# entrypoint outside them, or a library whose analysis closure adds dependencies
# its compile does not (`flutter_library`'s `sky_engine`). Takes the rule's
# `label` and `dart_info()`'s `packages`, `deps`, `srcs` and `resources`, and
# nests the `DartInfo` they make, so the target's own `package:<self>/…` imports
# resolve under the `dart_analyze` aspect rather than reporting
# `uri_does_not_exist`; `entry_srcs` adds the entrypoints outside every `lib/`,
# and a `lib/` file there is refused. Deliberately not what an executable
# returns for `deps` to see: `deps` requires `DartInfo`, and a binary is not a
# dependency.
dart_analyzable_info = _dart_analyzable_info

# The same wrapper for an executable that contributes no package, mirroring
# `dart_info_no_package`: takes `deps` and the `entry_srcs` that belong to no
# package's `lib/`, and nests a `dart_info_no_package()` closure beside them.
dart_analyzable_info_no_package = _dart_analyzable_info_no_package

# Every package a target's deps reach, one record per package: a package's
# records (one per `dart_library` of a split package, one per pub hub supplying
# it) are merged, each package-level fact taken from whichever record states
# it, and the build fails naming both targets when two state it differently.
collect_packages = _collect_packages

# The one record of a target that is itself a package — an app or test rule
# whose own sources are the package's `lib/` — in place of the records of the
# libraries rooted at its directory, which `package_config.json` cannot hold
# beside it. The same merge as [collect_packages]: every field those records
# state is carried through and code assets unioned. The target and the records
# name the same `dart_package_metadata`, so their facts agree by construction; a
# target naming none merges only with records naming none, and a record of
# another package at that root is an error.
#
#     identity = resolve_package_identity(ctx)
#     root = identity.package_root
#     packages = collect_packages(ctx.attr.deps)
#     at_root = [p for p in packages if p.package_root == root]
#     packages = [p for p in packages if p.package_root != root] + [
#         merged_package_record(ctx.label, identity.package_name, root, identity.metadata, at_root),
#     ]
merged_package_record = _merged_package_record

# The `short_path` prefix of a package's importable files, `<package_root>/lib/`
# (`lib/` for the root package): what decides whether a file is in a package
# and what its `package:` path is.
package_lib_prefix = _package_lib_prefix

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

# A program's packages: its own package's record (`executable_package_record`,
# or the record a rule whose sources are its package builds; `None` for a
# program in no package) and every package its `deps` reach, merged. The helpers
# below that collect what a program ships take the same `(package, deps)`, so
# the program's own package ships its assets and runs its link hook exactly as
# a dependency's does, as upstream's hooks runner treats the root package.
program_packages = _program_packages

# The runfiles a program needs from the libraries it depends on: the `data` of
# every `DartInfo` in `deps` and theirs (`dart_library.data`, or what a library
# rule of another rule set passes `dart_info()` as `data`). A rule merges
# the returned `runfiles` into its own:
#
#     runfiles = ctx.runfiles(files = ctx.files.data).merge(
#         collect_transitive_runfiles(ctx, ctx.attr.deps),
#     )
collect_transitive_runfiles = _collect_transitive_runfiles

# The code assets one `DartPackageInfo` declares. What a program ships is
# `dart_program_assets_actions()`'s.
package_code_assets = _package_code_assets

# The data assets one `DartPackageInfo` declares, each a
# `struct(package, name, file, id)` as `DartDataAssetInfo.assets` holds it. What
# a program ships is `dart_program_assets_actions()`'s.
package_data_assets = _package_data_assets

# The license text of one `DartPackageInfo`, or `None`, for a bundler building
# an app's license page. Read it off `collect_packages()`'s records, not the raw
# `transitive_packages`: two records for one package may differ in whether they
# name it, and the merge keeps the one that does.
package_license_file = _package_license_file

# The execution requirements of an action that may run once for every
# configuration building the same thing (`--experimental_output_paths=strip`):
# add them to an action whose arguments reach output paths only through Files
# (`Args.add`, `add_all`, `map_each`) and whose generated inputs name none.
PATH_MAPPING = _PATH_MAPPING
derive_package_root = _derive_package_root
derive_package_name = _derive_package_name

# Line coverage under `bazel coverage`, for a test rule that collects it from a
# Dart VM of its own (a Flutter test's, say) and converts it with
# `@rules_dart//dart:coverage_converter`.
#
# The rule merges `COVERAGE_ATTRS` into its `attrs`: the converter, and the
# `_lcov_merger` Bazel's coverage runner needs of a test rule. It gives its
# result `coverage_common.instrumented_files_info`, naming the sources to
# report. `test_coverage(ctx, packages, sources, deps)` is `None` unless the
# build is for coverage; otherwise it writes the file naming the packages'
# `lib/` directories and the runfiles path of each source Bazel instruments
# (the test's own `sources` and what its `deps` instrument), and returns
# `converter` and `sources` (runfiles paths to `rlocation`) and `runfiles` (to
# merge into the test's, carrying those sources: the converter leaves out the
# lines their `// coverage:ignore-*` comments name). Nothing is needed in the
# environment beyond the runfiles variables a test has. In the test, over a
# directory of `package:coverage` JSON (what `collect` returns), run
#
#     <converter> --hitmaps=<dir> --sources=<sources> --output=$COVERAGE_DIR/<name>.dat
#
COVERAGE_ATTRS = _COVERAGE_ATTRS
test_coverage = _test_coverage

# Source co-location: assemble a package whose hand-written and generated files
# straddle the source tree and `bazel-out` into one tree-artifact directory, so
# `part` directives and a single `rootUri` resolve at compile time. Any rule
# calling `colocate_packages` must declare
# `COPY_TO_DIRECTORY_TOOLCHAINS` in its `toolchains`.
colocate_packages = _colocate_packages
COPY_TO_DIRECTORY_TOOLCHAINS = _COPY_TO_DIRECTORY_TOOLCHAINS

# What a program ships, from inside another rule: what a bundler bundles, and
# what a rule compiling its own kernel embeds, which cannot depend on a
# `dart_program_assets` target without a cycle.
#
#     assets = dart_program_assets_actions(
#         ctx,
#         package = package,          # the program's own record, or None
#         deps = ctx.attr.deps,
#         name = ctx.label.name,
#         recorded_uses = uses,       # a DartRecordedUsesInfo to link, None not to
#         code_config = config,       # linked: the target's, for code assets
#         code_assets = own,          # the program's own DartCodeAssetInfo
#     )
#
# It returns `info`, the program's `DartProgramAssetsInfo`, and
# `validation_outputs`, for an `_validation` output group. The packages are
# `program_packages(package, deps)`. `code_config` is what each link hook is
# told of a target that loads code assets, upstream's
# `config.extensions.code_assets` object: a Dart VM program's is
# `vm_code_config(ctx)`, and a target loading none (the web) passes `None`. The
# link hooks run in `PORTABLE`: the rule declares `PORTABLE_EXEC_GROUPS`,
# merges `program_assets_attrs()` into its `attrs`, and declares
# `PROGRAM_ASSETS_TOOLCHAINS` in its `toolchains` and `fragments = ["cpp"]`,
# with which it links a package's `linked_code_assets` for the program.
#
# Read `info` with these:
#
#     a = program_assets_action_args(ctx.actions, info)
#     ctx.actions.run(
#         arguments = [own_args, a.args],
#         inputs = depset(own_inputs, transitive = [a.inputs]),
#         ...
#     )
#
# gives the tool `--program-assets=<file>`, a param file in the line format
# the README documents, which `ProgramAssets.read` from
# `@rules_dart//dart/program_assets` reads into the assets that ship; Bazel
# writes its paths mapped, so the action may support path mapping. A tool
# that reads less is handed less, and its action takes only those files:
# `data = False` leaves out the data assets, and `code = "names"` hands the
# code assets without their libraries, `code = None` not at all.
# `program_kernel_code_assets(info)` is every code asset the program can
# load, what its kernel maps (`dart_binary` and `dart_test` embed it), linked
# or not. `program_asset_file(info, id)` is the file of one asset known at
# analysis time, and fails naming the `link_hook_assets` to add when it is not.
dart_program_assets_actions = _dart_program_assets_actions
program_assets_attrs = _program_assets_attrs
PROGRAM_ASSETS_TOOLCHAINS = _PROGRAM_ASSETS_TOOLCHAINS
program_asset_file = _program_asset_file
program_assets_action_args = _program_assets_action_args
program_kernel_code_assets = _program_kernel_code_assets
vm_code_config = _vm_code_config
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
# `--@rules_dart//dart:modular_kernel=false` is the build-wide escape hatch:
# the aspect compiles no module, and every executable compiles its whole
# program from source. A rule merges `MODULAR_KERNEL_ATTR` into its `attrs`
# and, when `modular_kernel(ctx)` is false, compiles with
# `dart_whole_program_kernel_action` (below) rather than
# `dart_entry_kernel_action`, which fails if called then.
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

# A whole program compiled from source into one kernel, for any platform: what
# `dart_binary` compiles with, given the VM, and `dart_test` under
# `modular_kernel=false`. A rule set with its
# own platform, or a user with a Dart SDK or engine of their own (a fork, a
# local build), passes that platform's `DartKernelSdkInfo`, built for the
# `PORTABLE` host (`cfg = config.exec(PORTABLE)`), and names the runtime the
# kernel is for:
#
#     dart_whole_program_kernel_action(
#         ctx,
#         kernel_sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
#         runtime = "release",
#         main = ctx.file.main,
#         srcs = collect_transitive_srcs(ctx.attr.deps),
#         packages = collect_packages(ctx.attr.deps) + [own_package],
#         output_dill = dill,
#         entrypoint_uri = "package:app/main.dart",
#         flags = ["--aot", "--tfa"],
#         outputs = {"--recorded-uses": recorded_uses},
#         resource_set = _large_program,  # a top-level (os, inputs_size) -> dict
#     )
#
# The kernel names no path of the machine or the sandbox, so two output bases
# build the same bytes; the compile prints nothing when it succeeds, reads only
# the sources, the compiler, its runtime and one platform dill, and runs once
# for every configuration that builds the same program
# (`--experimental_output_paths=strip`). The rule merges `KERNEL_TOOL_ATTR`
# and declares `PORTABLE_EXEC_GROUPS`. Since no source is named by a path,
# `gen_snapshot --resolve-dwarf-paths` cannot be used on such a kernel.
#
# Each entry of `DartKernelSdkInfo.runtimes` is made by `dart_kernel_runtime`:
#
#     runtimes = {
#         "release": dart_kernel_runtime(
#             product_dill,
#             defines = ["dart.vm.product=true"],
#             flags = ["--delete-tostring-package-uri=dart:ui"],
#         ),
#     }
dart_whole_program_kernel_action = _dart_whole_program_kernel_action
dart_kernel_runtime = _dart_kernel_runtime
executable_defines_config = _executable_defines_config
executable_defines = _executable_defines
collect_modules = _collect_modules
dart_entry_kernel_action = _dart_entry_kernel_action
dart_link_kernel_action = _dart_link_kernel_action
kernel_package_config = _kernel_package_config
add_kernel_roots = _add_kernel_roots

# `--@rules_dart//dart:split_debug_info` makes `dart_binary` write the
# debugging information of an `exe` or `aot-snapshot` binary to `<name>.symbols`
# rather than into the binary. A rule compiling such a binary merges
# `SPLIT_DEBUG_INFO_ATTR` into its `attrs`; when `split_debug_info(ctx)` is
# true it declares that file, passes it to `dart_compile_action` as
# `debug_info`, and returns it in a `debug_info` output group.
#
# A launcher that runs a program through the VM gives it the file
# `empty_package_config(ctx)` as `--packages` (merge `EMPTY_PACKAGE_CONFIG_ATTR`
# into the rule's `attrs`, add the file to the launcher's runfiles and pass its
# `runfiles_path`), as `dart_binary` and `dart_test` do: the VM then does not
# look for a package config up from the program, where outside a sandbox it
# finds the workspace's own `.dart_tool` through the exec root.
#
# `dart compile` over a kernel, or over a script that imports only `dart:`
# libraries and `sources` beside it, in the toolchain's SDK (a cross
# toolchain's too): the one action `dart_binary` and the pub runner build
# their executables with. `sdk` is the `DartSdkInfo` of
# `@rules_dart//dart:toolchain_type`, and the rule declares that toolchain.
dart_compile_action = _dart_compile_action
KERNEL_TOOL_ATTR = _KERNEL_TOOL_ATTR
KERNEL_LIST_ATTR = _KERNEL_LIST_ATTR
SPLIT_DEBUG_INFO_ATTR = _SPLIT_DEBUG_INFO_ATTR
split_debug_info = _split_debug_info
EMPTY_PACKAGE_CONFIG_ATTR = _EMPTY_PACKAGE_CONFIG_ATTR
empty_package_config = _empty_package_config
kernel_list = _kernel_list
MODULAR_KERNEL_ATTR = _MODULAR_KERNEL_ATTR
modular_kernel = _modular_kernel
TRACK_CREATION_LOCATIONS_ATTR = _TRACK_CREATION_LOCATIONS_ATTR
track_creation_locations = _track_creation_locations
PORTABLE = _PORTABLE
PORTABLE_EXEC_GROUPS = _PORTABLE_EXEC_GROUPS
EXEC_TOOLS_TOOLCHAIN = _EXEC_TOOLS_TOOLCHAIN

# A rule whose `DartInfo` dependencies come from a toolchain names the toolchain
# types in a private `label_list` of this name, so the kernel module aspect
# reaches them: `DART_TOOLCHAIN_TYPES_ATTR: attr.label_list(default = [...])`.
DART_TOOLCHAIN_TYPES_ATTR = _DART_TOOLCHAIN_TYPES_ATTR

# Import checks (strict deps, files of the target's own package, layering,
# unused deps) as validation actions. An executable rule attaches
# `dart_import_check_aspect` to its `deps` and returns
# `OutputGroupInfo(**import_check_output_groups(ctx, ctx.executable._kernel_tool,
# own_srcs, own_package, ctx.attr.deps, generated = [...]))`, merging
# `KERNEL_TOOL_ATTR` into its `attrs`: `_validation`, and the group
# `bazel run @rules_dart//dart/unused_deps` reads. `generated` are the Dart
# files the rule writes and compiles with the target's (a test's bootstrap):
# their imports use `deps`, and they are not checked themselves.
# A library rule whose `deps` are what its `srcs` import checks itself, as
# `dart_library` does: it merges `LIBRARY_IMPORT_CHECKER_ATTRS` and takes
# `PORTABLE_EXEC_GROUPS`, and adds `library_import_check(ctx, own_packages)`
# to what it returns; the aspect then leaves it alone. A library left to the
# aspect is checked against its `DartInfo.deps` without the unused check.
dart_import_check_aspect = _dart_import_check_aspect
import_check_output_groups = _import_check_output_groups
LIBRARY_IMPORT_CHECKER_ATTRS = _LIBRARY_IMPORT_CHECKER_ATTRS
library_import_check = _library_import_check

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
