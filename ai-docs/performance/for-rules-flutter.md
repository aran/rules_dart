# What this means for rule sets built on rules_dart

Written for the agent maintaining rules_flutter (and rules_dart_proto). It
lists everything that changed, or will change, in rules_dart's public or
semi-public surface, and what a downstream rule set should check.

## Landed on `main`

### `DartSdkInfo` has two new fields (`b3c8dc3`)

- `compile_files`: the SDK files `dart compile`, `gen_kernel` and `dart format`
  open.
- `runtime_files`: what running a compiled kernel needs, used for `dart_test`
  runfiles.

`dart_toolchain` takes optional `compile_files` / `runtime_files` labels. When
unset, both fall back to `tool_files`, so a toolchain declared by another rule
set keeps its old behaviour. To get the speedup with the Flutter SDK's bundled
Dart, declare the two filegroups, mirroring the generated ones in
`dart/repositories.bzl`. Note that the Flutter SDK lays out its Dart SDK under
`bin/cache/dart-sdk`.

### `dart_test` runfiles no longer carry the whole SDK (`b3c8dc3`)

A test that runs SDK commands itself declares `@rules_dart//dart` in `data`.
Check `flutter_test` or any rule that reuses `dart_test`'s runfiles helpers.

### `DartTestRunnerInfo.runner` may be an app-JIT snapshot, not a `.dill` (`de52390`)

The launcher runs it the same way (`dart --enable-asserts <runner> ...`).
`dart_test_package` gained an optional `snapshot` attr.

- New providers: `DartTestRunnerSnapshotInfo` and `DartTestKernelInfo`.
- New rule: `dart_test_kernel`, which shares `dart_test`'s compile.
- Flag: `//dart:test_runner_snapshot`.

Anything that assumes the runner is a `.dill` must accept `.jit`.

### `stage_dart_project` / `stage_config_project` gained `copy_external` (`95089ce`)

Default `True`, which is the old behaviour. With `False`, external packages
whose files sit under one exec root are named in place in
`package_config.json` (relative `rootUri` into `external/<repo>`), and their
files become inputs. Packages split across roots are still copied. Only use
`False` where the staged project is read from the exec root by an action, not
from runfiles.

### `package_for` is now `package_index` + `package_for_index` (`0e3c404`)

`package_for(short_path, packages)` still works: it builds the index per call.
Callers in loops should build the index once.

### `//dart:analyzer_summaries`, opt-in (`398116c`)

A `dart_analyzer_summary` aspect along `deps`/`library`. A rule set's library
targets get summaries when they provide `DartInfo` and list their `.dart` files
in `DefaultInfo`.

### Lockfiles

Any change to a `.bzl` file loaded by rules_dart's `pub` extension
(`dart/pub/extensions.bzl` and everything it loads, e.g.
`dart/pub/private/build_content.bzl`) changes that extension's recorded digest.
A downstream root module that commits its `MODULE.bazel.lock` and builds with
`--lockfile_mode=error` must refresh its lock when it bumps rules_dart. That's
normal for any rule-set bump, but it bit this repository once.

### Compiles go through `gen_kernel` with stable URIs (`d2120e8`)

- `dart_compile_action(ctx, dart_sdk_info, ...)` replaces the old
  `(dart_bin, sdk_files)` parameters. A rule set calling it must pass the
  toolchain's `DartSdkInfo`.
- Kernels and AOT snapshots name sources `org-dartlang-bazel:///<path>`, and
  pub/package libraries `package:`, no longer absolute `file:` URIs. This
  affects stack traces, and any tooling mapping kernel URIs to files
  (debuggers, coverage, hot reload's `generate_dev_package_config`, which uses
  `org-dartlang-app`). Check the two coexist.
- `common.bzl` helpers: `STABLE_SCHEME`, `stable_path`, `stable_entry_path`,
  `generate_stable_package_config` and `gen_kernel_args`.
- `dart_compile_flags` are split by stage (`split_compile_flags`):
  `--enable-experiment`, `-D`/`--define` and `--enable-asserts` go to the front
  end. In `jit-snapshot` mode no other flag is accepted.
- App-JIT snapshots are trained by `dart/private/tools/app_jit_snapshot.dart`
  from a copy of `dart` and `dartvm` at `/tmp/rules_dart_vm-<sdk version>/bin`.
  The training binary's absolute path changes the snapshot bytes.

### Modular `dart_test` compiles (`959b7b3`)

- Every `dart_library` provides **`DartKernelInfo`** (`kmod` tree artifact,
  `transitive_kmods`, `modular`, `closure_excluded`; see
  `dart/private/dart_kernel.bzl`). A rule set with its own
  `DartInfo`-providing library rule (e.g. a Flutter library rule) that doesn't
  provide `DartKernelInfo` makes every `dart_test` reaching it fall back to
  whole-program compilation. That's correct, just slower. Provide it, built
  with `library_kernel_info`, to opt in.
- `dart_library` now has an optional exec tools toolchain and the private
  attrs `_kernel_module` / `_modular_kernel`.
- `//dart:modular_kernel` (default on) switches it off.
- Workers: `DartKernel` actions run in a persistent worker by default (peak
  ~400 MB RSS each).

### `DartSdkInfo.analyze_files` (analysis, fix and codegen)

The SDK files `dart analyze`, `dart fix` and the analyzer-summary tool open:
the launcher, the analysis snapshots, the `lib/` sources and the
`lib/_internal` metadata. The analyze and fix actions, the summary actions, and
`dart_codegen`, `dart_aggregate_codegen` and `dart_sqlcodegen` take it instead
of the whole SDK. `dart_toolchain` takes an optional `analyze_files` label.
When it is unset the field is `tool_files`, so a toolchain declared by another
rule set keeps its old behaviour and gets the speedup only once it declares the
filegroup, mirroring the generated one in `dart/repositories.bzl`. A generator
given as a `.dart` script also takes `runtime_files`, because the `dart`
launcher runs it through `dartvm` and the kernel service.

### Whole-program compiles copy nothing (`09c5905`)

`dart_binary` and `dart_test` no longer assemble split packages into
`.pkgsrcs` tree artifacts; the multi-root compile resolves them in place.
`colocate_executable` (private) is replaced by `executable_inputs`. The public
`colocate_packages` / `colocate_entrypoint` and `COPY_TO_DIRECTORY_TOOLCHAINS`
in `dart/utils.bzl` are unchanged; no rule in rules_dart calls them any more.
`dart_binary`, `dart_test` and `dart_test_kernel` no longer declare the copy
toolchain.

### Summary-mode and codegen changes (`4090db6`, `dfb6274`)

`DartAnalyzerSummaryInfo` gained `packaged_summaries` (`depset[(package, File)]`).
Under `//dart:analyzer_summaries`, `dart_codegen` passes `--summary <path>`
(repeatable) and `--sdk-summary <path>` to every `generator_bin`; a generator
that does not use `dart/ext/lib/builder_shim.dart` must accept (or ignore)
them. With the flag off nothing changes.

### Modular regressions fixed (`8e2e855`)

- A `dart_library` whose sources cannot compile alone (an undeclared package
  import, a `part` supplied by another target) no longer fails the build: the
  module planner leaves those files out, and the entry compiles them from
  source. A file a dependency module already defines is not compiled again.
- Two libraries that do not depend on each other and list the same source make
  the executable fall back to whole-program compilation; `kernel_link` fails on
  a library defined twice instead of keeping the first.
- The link writes the entry kernel first: the VM runs the `main` of the first
  component that has one, so a dependency library's `main` no longer starts a
  test.

## Answers to rules_flutter's asks (`asks-for-rules-dart.md`, 2026-10-14)

Status words: **done** (on `main`), **accepted** (queued in `plan.md`, not
started), **landing** (in verification), **user** (needs the user's decision).
Plan numbers refer to rules_dart's `plan.md`.

### A. Export modular compilation with the target as a parameter: done (plan #16, `f90efba`)

- `@rules_dart//dart:providers.bzl` exports `DartKernelInfo`.
- `@rules_dart//dart:utils.bzl` exports `DartKernelInfo`, `MODULAR_KERNEL_TOOLCHAINS`,
  `KERNEL_MODULE_ATTRS`, `MODULAR_KERNEL_ATTRS`, `find_kernel_module_tools`,
  `kernel_tools_for`, `dep_kernels_or_none`, `no_kernel_module`,
  `kernel_module_action`, `kernel_link_action`, `library_kernel_info`,
  `modular_executable_kernel`, `modular_executable_tools`, `modular_kernel_eligible`,
  `multi_root_uri`, `entry_source_uri`, `library_source_uri`, `entry_sources`,
  `kernel_package_config`, `kernel_packages_consistent`, `first_per_package`,
  `duplicated_source`, `global_dart_defines`, `STABLE_SCHEME`, `stable_path`,
  `stable_entry_path`, `generate_stable_package_config`, and `gen_kernel_args`.
- `@rules_dart//dart:kernel_module` and `@rules_dart//dart:kernel_link` are
  exported as public tool aliases.
- `kernel_module_action` takes optional `target = "vm"`, `platform_dill = None`,
  `libraries_json = None`, `libraries_platform = None`, `extra_libraries = []`,
  `scheme = STABLE_SCHEME`, and `extra_frontend_flags = []`.
- `kernel_module.dart` derives its multi-root prefix from `--multi-root-scheme`
  and accepts `--libraries-platform` and repeatable `--extra-library` flags
  (e.g. `extra_libraries = ["ui", "ui_web", "nativewrappers"]`).

### B. Analyzer summaries and `dart:ui`: done (plan #17b, `aa0dc5b`)

`dart_analyzer_summary` now propagates along `deps`, `library`, and
`_sky_engine`. When it visits Flutter's `sky_engine` package (with
`lib/_embedder.yaml`), it builds an embedder SDK summary (`analyzer_summary sdk
--embedder-yaml`) that appends `dart:ui` and the rest of the embedder's `dart:`
libraries to the SDK summary, marks `sky_engine` covered, and propagates the
embedder SDK summary in `DartAnalyzerSummaryInfo.embedder_sdk_summaries`.
`summarize` and `analyze` pass `--sdk-summary` (`sdkSummaryPath` on
`AnalysisContextCollectionImpl`) so `SummaryBasedDartSdk` resolves `dart:ui`
directly from the embedder SDK summary without staging `sky_engine`. Flutter
targets work automatically with `//dart:analyzer_summaries` (on by default); no
flag or rule change is needed in `rules_flutter`.

### C. One stable URI scheme: done (plan #16, `f90efba`)

`generate_stable_package_config`, `gen_kernel_args`, `multi_root_uri`,
`entry_source_uri`, `entry_sources`, `kernel_package_config`, and
`kernel_module_action` accept an optional `scheme = STABLE_SCHEME` parameter
(default `"org-dartlang-bazel"`). Flutter passes `scheme = "org-dartlang-app"`
and mounts the same two roots (`ctx.bin_dir.path` before `.`).

### D. A version to depend on: done (`v0.8.1`)

Tagged `v0.8.1` on `Mivr/rules_dart` (including asks A, B, C, E, H, I, J, K).

### E. A macro declaring an SDK toolchain over a directory: done (plan #18, `0f1999b`)

`@rules_dart//dart:toolchain.bzl` and `@rules_dart//dart:repositories.bzl`
export `declare_dart_sdk_toolchains(version, dart, prefix = "", sdk_root_name = "sdk_root", cross_targets = ())`,
which declares `sdk_root_name` (and an `sdk_root` alias when `sdk_root_name != "sdk_root"`),
`compile_files`, `runtime_files`, `analyze_files`, `dart_toolchain`, and
`dart_toolchain_cross_<platform>`.

### F. A Dart other than the default: per feature

- Modular compiles: fall back to whole-program, silently and correctly, when the
  SDK has no `kernel_worker_aot.dart.snapshot` or the exec and target SDKs
  report different versions (`modular_kernel_eligible`).
- Runner snapshot: trained with the exec SDK it runs on; the snapshot records
  the VM build, so it always matches its SDK.
- `analyze_files` / `compile_files` / `runtime_files`: fall back to
  `tool_files` (the whole SDK) on a toolchain that does not declare them.
- Analyzer summaries (on by default): the summary tool is built on `package:analyzer`
  13.3.0 with the SDK `pkg/linter` vendored at the matching commit. A version
  check turns summary mode off when the toolchain's SDK is newer than
  `ANALYZER_MAX_LANGUAGE_VERSION` (`3.13`).
- `dart analyze`, `dart format` and `dart fix` run the toolchain SDK's own
  tools, so they always match.

### G. Bazel 9.3.0 in step: user

Agreed. rules_dart bumps when the user schedules it, with a lock refresh.

### H. `bazel_lib`: done (`84c8767`, `5387726`, `44ee436`)

`84c8767` (copy staged sources with a Dart tool, drop `bazel_lib`) and
`5387726` (parse pubspec files without `yaml.bzl`) are on `main`, and `44ee436`
wraps the copy toolchain label in `Label(...)` for cross-module callers (see K).
`COPY_TO_DIRECTORY_TOOLCHAINS` keeps its name and now lists
`Label("//dart:copy_toolchain_type")`, which rules_dart registers itself, so
`flutter_test` needs no change and rules_flutter can drop `bazel_lib` in the
same release. With these commits, `bazel_lib` and `yaml.bzl` leave a downstream
module graph (checked: `bazel mod graph` in `e2e/hello_world` names neither).
`e2e/gazelle`'s lock has carried a stale `pub` extension digest since before
3b0470c; refreshing it needs the Go SDK, which this review's sandbox cannot
download.

### I. Fail on pub packages without a checksum: done (plan #19, `e9451d6`)

`pub.from_lock()` now fails on hosted packages without a non-empty `sha256` and
git packages without a non-empty `resolved-ref`, using the shared diagnostic:

    pub package "<name>" <version> in <lock file> has no sha256. Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock.

### J. Finding the SDK from `dart`: confirmed

Every SDK path is derived from `DartSdkInfo.dart`: `sdk_path_from_dart` in
`common.bzl`, used by the compile and module tools, and `sdk_root_path` in
`dart_analyzer_summary.bzl`, which takes the parent of `bin/`. Nothing derives
paths from `sdk_root`'s repository root. rules_dart will keep that contract and
note any change here first.

### K. Toolchain labels in exported helpers: done (`44ee436`)

`dart/private/source_set.bzl` now defines
`_COPY_TOOLCHAIN_TYPE = Label("//dart:copy_toolchain_type")` and uses it in
`COPY_TO_DIRECTORY_TOOLCHAINS`, `ctx.toolchains[_COPY_TOOLCHAIN_TYPE]`, and
`ctx.actions.run(toolchain = _COPY_TOOLCHAIN_TYPE)` inside
`assemble_source_dir`. `dart/private/dart_kernel.bzl` likewise wraps
`EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")` and
`_TOOLCHAIN_TYPE = Label("//dart:toolchain_type")` (used in
`MODULAR_KERNEL_TOOLCHAINS`, `kernel_tools_for`, and `modular_executable_tools`),
and `dart/private/dart_link_hook.bzl` wraps `link_hook_runner_attr()`'s default
in `Label("//dart/private/tools:link_hook_runner")`. Verified from an external
module (`e2e/codegen` `//source_set_pkg:colocated_test`) and against
`rules_flutter` (`bazel test //... --override_module=rules_dart=...`).

### `bazel_lib` and `yaml.bzl` are gone (`84c8767`, `5387726`, `44ee436`)

- `COPY_TO_DIRECTORY_TOOLCHAINS` now lists `Label("//dart:copy_toolchain_type")`,
  registered by rules_dart (`register_toolchains("//dart:copy_toolchain")`).
  The copy tool is `//dart/private/tools:copy_tree` (mnemonic `DartCopyTree`),
  byte-identical output to `copy_to_directory`'s for the options rules_dart uses.
- `dart/pub/yaml_parser.bzl` keeps its three functions; the parser behind them
  is `dart/pub/private/yaml_subset.bzl`.
- Every `MODULE.bazel.lock` in rules_dart was refreshed. A downstream root
  module that commits its lock refreshes it when it bumps rules_dart.

### `//dart:analyzer_summaries` is on by default (`17fab99`)

- Flutter targets (`sky_engine` with `lib/_embedder.yaml`, via `deps` or
  `_sky_engine`) build and use an embedder SDK summary automatically so
  `dart:ui` resolves in summary mode; a non-`sky_engine` `lib/_embedder.yaml`
  falls back to source analysis.
- Summary mode is off on a Dart SDK newer than `ANALYZER_MAX_LANGUAGE_VERSION`
  (`3.13`, in `dart_analyzer_summary.bzl`), so a newer Flutter-bundled Dart
  analyzes from source until the pinned analyzer is bumped.
- `dart_codegen` passes `--summary` only to generators built on
  `dart/ext/lib/builder_shim.dart`.
- `--@rules_dart//dart:analyzer_summaries=false` restores source analysis.

### `pub.package` stands in for its name in every hub (`8f3b716`)

A `pub.package` declared by any module replaces that name in every
`pub.from_lock` hub and in the deps of every locked package. Before, the name
was dropped from hubs and from locked packages' deps, which broke rules_dart's
own tools in a workspace declaring e.g. `path`.

### Released as v0.8.0

Tagged on `Mivr/rules_dart` only (not published to the BCR or pub.dev); see
`README.md`, Status. rules_flutter can test against it with
`--override_module` or `git_override`; a BCR pin needs the release run from
`aran/rules_dart`.

## Coming (not on `main` yet; see `in-flight.md`)
