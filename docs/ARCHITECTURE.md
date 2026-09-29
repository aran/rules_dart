# rules_dart — Architecture & Design

## Overview

`rules_dart` is a Bazel rule set for the Dart language. It:

- Downloads published Dart SDK releases (not building from source)
- Uses bzlmod exclusively, targeting Bazel 9.x
- Is designed for future extension by a `rules_flutter` rule set

---

## Provider Design

| Provider                  | Level        | Purpose                                                                                                                            |
| ------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `DartSdkInfo`             | Toolchain    | SDK binaries (`dart`, `dartaotruntime`), SDK root, version, tool_files                                                             |
| `DartInfo`                | Library      | Package name, lib_root, transitive_srcs, transitive_resources, transitive_packages, transitive_code_asset_files                    |
| `DartPackageInfo`         | Metadata     | One package's name, lib_root, version, language version, code assets, unreplaced-hook path (carried in DartInfo depsets)           |
| `DartPackageMetadataInfo` | Declaration  | The name and language version a `dart_package_metadata` states, read back through an attribute by every rule building that package |
| `DartAnalyzableInfo`      | Executable   | An executable's analyzable closure: a nested `DartInfo`, plus its own entrypoint sources                                           |
| `DartPackageConfigInfo`   | Build action | Generated package_config.json file                                                                                                 |
| `DartCompileInfo`         | Binary       | Compiled output file, compile_mode string                                                                                          |

**DartInfo contains zero Flutter concepts.** A future `rules_flutter` wraps/extends, never modifies.

**One package name can reach a target through two records, and they must agree.** Two pub hubs independently supplying one package — rules*flutter's `flutter.pub()` and rules_dart's `pub.from_lock()` both generating a spoke for `ffi` — is normal and supported, as is a package deliberately split across `dart_library` targets. Deduplication keeps the first record, so where two records disagree, dependency order silently decides which one's entire source tree is used: a pair of lock files that drift apart compiles a package against sources its own lock does not pin, with nothing reported. `merge_package_records` therefore refuses that outright, via `package_agreement_error`, whenever two records state different `version`s or `language_version`s. Only two \_known* values can conflict — the fields are optional and a producer that does not emit one carries `""` — which is what lets a rule set outside rules_dart adopt them on its own schedule rather than in lockstep. `has_unreplaced_hook` stays order-decided on purpose: it is derived at repository generation rather than stated by a developer, and two hubs can legitimately disagree when one curates `code_assets` and the other does not.

**A package's name and language version are stated once, and the rules building it are checked against each other.** `package_name` and `language_version` describe a package, not a rule, and a package is routinely built by several rules — a `dart_codegen` producing part of it and the `dart_library` collecting the result, sometimes in different BUILD files, where no macro can hold them together. `dart_package_metadata` declares both once and the rules reference it with `package = ":pkg"`; setting `package` and an inline attribute on the same rule fails, whether or not they currently agree, so there is never a silently ignored value. Where the inline attributes are still used — they remain the contract, and are what generated spoke repositories emit, a generator writing both from one derived value having no duplication to remove — `codegen_identity_error` compares the generator's effective identity against the library that collects its output at the one point the two meet, that library's `srcs`. Gazelle emits the inline form by default and switches to references in any directory that already declares a `dart_package_metadata`, so adopting one is incremental and re-running Gazelle never undoes it.

**`DartInfo` means "valid as a dep"; `DartAnalyzableInfo` means "has Dart sources to analyze".** Every `deps` attribute in this rule set and in the ones built on it gates on `providers = [DartInfo]`, so which provider a target hands out is what decides whether it can be depended on. That is why `dart_binary`/`dart_test`/`dart_js_binary`/`dart_wasm_binary` deliberately provide only the second: an executable is not a dependency, Bazel has no negative provider constraint to say so, and returning `DartInfo` would silently make `dart_library(deps = [":some_binary"])` legal. The `dart_analyze` aspect accepts either, which is also what keeps `dart_proto_library` analyzable with no adoption work — the `DartInfo` branch is permanent, not a migration shim. A library needs nothing extra because for a library `DartInfo` already _is_ the analyzable closure and its `DefaultInfo` lists its own sources; an executable needs the wrapper because its `main` lives outside every package's `lib/`, so no `DartPackageInfo` can name it and no `package:` URI reaches it. The wrapper nests a `dart_info_no_package()`-built `DartInfo` rather than restating its fields, for exactly the reason `dart_info()` exists: a provider re-enumerating `transitive_srcs`/`transitive_resources`/`transitive_packages` would be a second place for a merge to be forgotten.

**An executable may state the package it belongs to, and every other statement of that package must agree.** A package with no `dart_library` — a directory of scripts, a test-only package — has nothing to state its language version, so the executable rules accept the same `package` / `package_name` / `language_version` a library does (`executable_package.bzl`, through the same `resolve_package_identity`). Unset, nothing changes: the executable carries no package, and its entrypoint takes the version of the package whose root contains it. Set, the executable is a member of a package rooted at its Bazel package directory, as a `dart_library` there would be: its `DartAnalyzableInfo` is built with `dart_analyzable_info_with_package`, so analysis and the format check read the version from its own record, and its own record joins the package list it compiles against. `colocate_executable` makes its entrypoint sit inside that package's root in the compile: its files are members of the package for colocation, so when the package's `lib/` is assembled with generated files, the entrypoint is assembled into the same directory, and when nothing is assembled the root is its source directory, which `generate_package_config` is told outright because no `lib/` file may reveal it. A stated identity is a second statement of facts `deps` may already carry, so `executable_package_error` refuses each disagreement: an own file outside the package root, or inside a package in `deps` rooted deeper (Dart would give the file that package's version); a name that `deps` supply only at other roots (one package, one root — a name reached at several roots stays legal, as for split packages and dual pub hubs, provided one of them is this root); another name at the same root (one directory, one package); and a record of the same package stating a different `language_version`, stated or not, because the executable's record would otherwise decide the library's version in that one build. A package in `deps` whose root merely contains the executable's under another name is a nested package — a pub package's `example/` — and Dart gives the nested one's files its own version, so that is allowed. Generated `srcs` it collects are checked with `codegen_identity_error`, as for a library.

**Read `DartInfo` directly; build it through `dart_info()`** (`//dart:utils.bzl`). Rule sets outside rules*dart produce `DartInfo` too — `rules_flutter`'s `flutter_library`, `rules_dart_proto`'s `dart_proto_library` — and constructing it by hand means enumerating every field and merging every transitive depset one at a time. That made each added field a breaking change for all of them, and left each to work out independently how the new field merges. `dart_info()` takes what a target contributes itself and merges its dependencies' closures internally, so a new field is a change to one function. It also removes a failure that is invisible in review: a missing field's correct fix (forward the dependencies' values) and its tempting fix (declare it `depset()`) look identical in a diff, and the second silently drops every dependency's contribution at that boundary. A target that deliberately ships no package of its own — `flutter_material_icons` carries a font and no Dart — calls `dart_info_no_package()` instead: it merges its dependencies' closures the same way, and contributes no package record. The same hazard applies to \_copying* a `DartPackageInfo` with a field overridden, so rules_dart routes that through one internal `derived_package_info()` rather than restating the field list at each call site; a copy that forgets a field drops it only for the targets that take that path, which is harder to spot than losing it everywhere.

---

## Dart Compilation Model

Unlike Go/Rust, Dart does not produce intermediate object files for libraries. The compiler takes the full transitive source tree. Therefore:

- `dart_library` is **source-only** — it collects sources and propagates `DartInfo`
- Compilation happens in `dart_binary`, `dart_test`, `dart_js_binary`, `dart_wasm_binary`

A `dart_library`'s `srcs` must live under `<lib_root>/lib/`, because `package:<name>/x.dart` resolves to `<lib_root>/lib/x.dart` and the consumer stages a package by stripping `lib_root`. This is checked at analysis time (`check_files_under_lib_root`); without it a stray file surfaces only as a missing path inside a `.pkgsrcs` directory at kernel-compile time, naming neither the target nor `lib/`. Generated sources obey the same rule: `declare_file` paths are relative to the _producing_ rule's package, so a codegen target outside the Dart package root emits a path that no longer starts with `lib_root`. Targets using `srcs_dir` are exempt — a `dart_source_set` is already assembled, and its directory is the package root.

- `package_config.json` is generated at build time from the transitive `DartInfo` graph to bridge Bazel's dep model with Dart's `package:` URI resolution

---

## Design Decisions

1. **Bazel version**: Bazel 9.x only. bzlmod required.
2. **Platforms**: five **hosts**, for which an SDK is downloaded and a build can run — macos-arm64, macos-x64, linux-x64, linux-arm64, windows-x64 — plus two **cross-only targets** that can be built _for_ but not _on_: linux-riscv64 and linux-arm (armv7). See [Cross-Compilation](#cross-compilation).
3. **Compilation modes**: `dart compile exe` (default), `aot-snapshot`, `kernel`, `jit-snapshot`, plus `dart_js_binary` (JS) and `dart_wasm_binary` (WASM) for web.
4. **pub.from_lock**: Only `hosted` packages are resolved. `git`/`path` sources produce a warning and are skipped. `sdk` sources are silently skipped (provided by the toolchain).
5. **Gazelle plugin**: `rules_go` and `gazelle` are non-dev dependencies so `//gazelle/dart` is loadable from downstream modules. See the comment in `MODULE.bazel` for the full rationale. The Go SDK is only fetched if a target in `//gazelle/...` is actually built. Supports `gazelle:resolve` directive for explicit dependency overrides.
6. **Code generation**: `dart_codegen` (per-file), `dart_aggregate_codegen` (package-level), and `dart_sqlcodegen` (drift's `.drift` preprocessor) provide Bazel-native alternatives to `build_runner`. Each runs `package:build` `Builder`s via per-builder AOT shims under `dart/ext/*/`. A Bazel persistent worker amortises Dart-VM startup across requests, but the `AnalysisContextCollection` itself is constructed fresh per request (reusing one across requests would silently corrupt `source_gen`'s process-pinned `rootPackageName`). See [`docs/ext.md`](./ext.md) for the shim contract, Gazelle synthesis, and dual-build migration guide.
7. **Analysis and the format check are an aspect**: `dart_analyze` (`//dart:analyze.bzl`) is applied from `.bazelrc` under `bazel test`, so `bazel run` never pays for it and `bazel test` is where correctness is enforced. Each check is a separate action in its own output group — `dart_analyze` for the analyzer, `dart_format` for `dart format --set-exit-if-changed` — so a repository runs the checks whose groups its `.bazelrc` requests and no others; `no-dart-analyze` and `no-dart-format` opt a target out of one each. It checks only the targets named on the command line (it does not propagate along `deps`) and only each target's own hand-written files — `DefaultInfo` `.dart` files plus `DartAnalyzableInfo.srcs` — staging in-repository dependencies to resolve against and excluding them through the staged root options file; each is checked when it is itself named. Targets in other repositories are skipped: their module checks them under its own options. Options come from one `dart_analysis_config`, named by the `//dart:analysis_config` label flag, that lists every `analysis_options.yaml` in the repository. All of them are staged at their workspace paths and the SDK's own nearest-file rule picks one per file, so Bazel and the IDE cannot disagree about which options govern a file. The formatter finds its `formatter:` section by the same walk over the same staged tree; the rules_dart-written options file at the staged root ends that walk, so a file no listed options govern gets stock defaults rather than whatever sits above the project. The format check names the target's own files and passes the target's own language version, which selects the formatting style. An options file's own diagnostics (an unresolvable `include:`) fail only targets with files beneath it; the format runner escalates the formatter's warning about the same, which would otherwise silently fall back to defaults.
8. **Source rewriting**: `dart_fix` runs the analyzer's automated fixes. The `dart_analyze` aspect computes them hermetically, over the same staged project it analyzes, in the `dart_fix_fixes`/`dart_fix_manifest` output groups; `dart_fix` applies the aspect to its `target` and `bazel run` copies the result into the workspace. Only the target's own files that Bazel records as `is_source` are ever written back, which is what keeps codegen output resolvable to its importers without being editable; `dart fix`'s own generated-file heuristic cannot be relied on, since it matches `*.g.dart` and no other name. Both products are exposed as output groups (`dart_fix_fixes`, `dart_fix_manifest`) so they can be inspected without running a tool that rewrites sources. `dart_format` is the `bazel run` counterpart of the format check, and works the other way round: the files to format are named on the command line, so no build action can know them. The build stages, with the aspect's own staging code (`stage_config_project`), exactly what the check stages around the sources — every listed options file at its workspace path, the packages their `include:`s resolve against, and the root options file — and the runner copies that and each named file, at its workspace path, into a scratch project, formats them there, and writes back the ones that changed. The copy is what makes the settings match the check: `dart format` finds both its options file and the package config that resolves a `package:` include by walking up from each file, and in a Bazel workspace that walk finds no package config.
9. **Test runner**: Bazel defines how a test framework honours `--test_filter` (`TESTBRIDGE_TEST_ONLY`), sharding (`TEST_TOTAL_SHARDS`, `TEST_SHARD_INDEX`, `TEST_SHARD_STATUS_FILE`), per-case results (`XML_OUTPUT_FILE`) and time limits (`size`/`timeout`), and where Bazel defines one, Bazel's wins. A `package:test` file run directly implements none of that and applies its own 30-second per-case timeout, so `dart_test` runs such tests under `package:test`'s runner with `--precompiled`: the test is still compiled at build time, from a generated bootstrap that hands `main` to the runner, and the launcher translates Bazel's variables into runner flags, passes `--timeout=none`, and converts the runner's JSON report into JUnit XML. The runner and the test talk over a protocol private to one `package:test` version, so the runner is built from the user's own `package:test`, once, in that package's pub spoke: the spoke's public `test` target forwards the library and carries the runner (`DartTestRunnerInfo`), and `dart_test` takes it from its direct deps. A test without `package:test` runs directly and refuses a filter or shards rather than reporting a selection that never happened.

---

## Cross-Compilation

Dart's AOT compiler supports cross-compilation via `--target-os` and `--target-arch` flags on `dart compile exe` and `dart compile aot-snapshot`. No separate SDK is needed — the host SDK can produce binaries for other platforms.

### How It Works

Each SDK repository generates both a **native** `dart_toolchain` target (no `target_os`/`target_arch`) and **cross** `dart_toolchain_cross_{target}` targets for each supported cross-compilation pair. The toolchains repository registers:

- **Native toolchains** (5): `exec_compatible_with` and `target_compatible_with` match the same platform
- **Cross toolchains** (18): `exec_compatible_with` = host, `target_compatible_with` = cross target
- **Exec-tools toolchains** (5): `exec_compatible_with` = host, `target_compatible_with` omitted — for the codegen rules (see [Toolchain Types](#toolchain-types))

When `--platforms` is set, Bazel's toolchain resolution picks the cross toolchain. `DartSdkInfo` carries `target_os`/`target_arch`, which `dart_compile_action` passes as `--target-os`/`--target-arch` flags.

Two tables in `dart/private/toolchains_repo.bzl` drive this. `PLATFORMS` holds the hosts: each entry downloads an SDK, so each costs one SHA-256 per pinned version in `versions.bzl`. `TARGET_ONLY_PLATFORMS` holds destinations that are never built _on_ — a cross toolchain reuses the **host** SDK's `dart` binary, so no SDK is fetched for the target and no checksum is needed. `TARGET_PLATFORMS` is the union and is what a cross target is looked up in. `linux-riscv64` and `linux-arm` are target-only because Bazel publishes no release for either CPU, so neither can ever be an exec platform.

### Supported Cross-Compilation Matrix

| Host (exec) | Target                                           |
| ----------- | ------------------------------------------------ |
| macOS arm64 | linux-x64, linux-arm64, linux-riscv64, linux-arm |
| macOS x64   | linux-x64, linux-arm64, linux-riscv64, linux-arm |
| Linux x64   | linux-arm64, linux-riscv64, linux-arm            |
| Linux arm64 | linux-x64, linux-riscv64, linux-arm              |
| Windows x64 | linux-x64, linux-arm64, linux-riscv64, linux-arm |

`linux-arm` is Dart's armv7 hardfloat target and is selected by `@platforms//cpu:armv7`. Note `@platforms//cpu:arm` is an **alias for `aarch32`** — a different constraint value — and constraint matching has no subtyping, so a platform declaring `:arm` will not resolve the toolchain.

### Usage

Define a platform and set `--platforms`:

```python
# BUILD.bazel
platform(
    name = "linux_x64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
)
```

```sh
bazel build //:my_binary --platforms=//:linux_x64
```

### Limitations

- Only `exe` and `aot-snapshot` compile modes support cross-compilation. `kernel` and `jit-snapshot` are VM formats and ignore target flags.
- `dart_js_binary` and `dart_wasm_binary` output is platform-independent — no cross-compilation needed.
- `dart_test` runs on the host — cross-compiled tests are not supported.
- **Cross-compiling requires network access at action time.** `dart compile` downloads the pair-specific `gen_snapshot_{host}_{target}` and, for `exe`, `dartaotruntime_{target}` into `$HOME/.dart/dartdev/sdk_cache/{version}` (`HOME` is pinned to `/tmp` by `dart_compile.bzl`). This is not new to the riscv64/armv7 targets — it already applied to linux-x64 and linux-arm64 — but it does mean a sandbox that denies network cannot run a cross-compile action.
- Native **code assets** on linux-riscv64 and linux-arm work only if you supply a cc toolchain for that CPU; rules_dart ships none. The ABI mapping is in place (`linux_riscv64`, `linux_arm`), so rules_dart itself will not block you — an unresolvable cc toolchain surfaces as Bazel's own error.

## Toolchain Types

rules_dart exposes **two** toolchain types, registered together by `dart_register_toolchains` (so `register_toolchains("@dart_toolchains//:all")` picks up both):

- **`//dart:toolchain_type`** — target-configuration. Used by the rules that produce target-platform artifacts: `dart_binary`, `dart_test`, `dart_js_binary`, `dart_wasm_binary`, plus the `dart_analyze` aspect and `dart_format`. Registered native (exec == target) and cross (exec = host, target = cross target) — so resolution depends on the build's target platform, which is correct for compilation.

- **`//dart:exec_tools_toolchain_type`** — exec-configuration. Used only by the build-time code generators: `dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen`. These run a generator on the exec/host machine and emit **platform-agnostic Dart source**, so SDK selection must not depend on the target platform. Its toolchains are registered one per host platform with `exec_compatible_with` pinned and **`target_compatible_with` omitted**, so each matches _any_ target platform. Both types reuse the same native `dart_toolchain` (the host SDK) — there is no separate SDK download.

This split is why codegen resolves even under a target platform rules_dart registers no compile toolchain for — e.g. a downstream Flutter build that puts the whole graph on `@platforms//os:ios` or `:android`. Were codegen on `//dart:toolchain_type`, it would fail with "No matching toolchains found" for those targets even though the generator runs fine on the host. (Regression-guarded by `e2e/codegen/foreign_platform`, which builds a codegen target under a synthetic toolchain-less platform.)

> Migration note: modules that register via the `@dart_toolchains//:all` glob get both types automatically. A module that instead hand-registers _specific_ dart toolchains must also register the `*_exec_tools_toolchain` targets, or codegen will fail to resolve.

---

## Compilation Modes

Bazel's `-c` flag (`fastbuild`, `dbg`, `opt`) controls compiler flags automatically. Rules read `ctx.var["COMPILATION_MODE"]` and map it to Dart compiler flags. Per-target overrides are available via the `dart_compile_flags` and `defines` attributes; `dart_test` takes `defines` only, since its compile mode is fixed.

### Flag Mapping

**dart_binary (exe / aot-snapshot)**

| Bazel Mode  | Flags                                                 |
| ----------- | ----------------------------------------------------- |
| `fastbuild` | _(none)_                                              |
| `dbg`       | `--enable-asserts`                                    |
| `opt`       | `--extra-gen-snapshot-options=--optimization_level=2` |

**dart_binary (kernel / jit-snapshot)**

| Bazel Mode  | Flags              |
| ----------- | ------------------ |
| `fastbuild` | _(none)_           |
| `dbg`       | `--enable-asserts` |
| `opt`       | _(none)_           |

**dart_js_binary**

| Bazel Mode  | Flags                              |
| ----------- | ---------------------------------- |
| `fastbuild` | _(none — dart2js defaults to -O1)_ |
| `dbg`       | `--enable-asserts -O0`             |
| `opt`       | `-O2`                              |

**dart_wasm_binary**

| Bazel Mode  | Flags              |
| ----------- | ------------------ |
| `fastbuild` | _(none)_           |
| `dbg`       | `--enable-asserts` |
| `opt`       | _(none)_           |

### Per-Target Attributes

- **`dart_compile_flags`** (`string_list`): Extra flags appended after mode defaults. Appears last so user flags override defaults (e.g., `-O4` after `-O2` — dart2js uses last-wins).
- **`defines`** (`string_list`): Entries in `key=value` format. Each becomes a `-Dkey=value` flag passed to the compiler. These are resolved by the front end during constant evaluation, so they must reach whichever action compiles source — with code assets that is `gen_kernel`, not the `dart compile` step that consumes its kernel.

### Command-Line Defines

`--@rules_dart//dart:extra_dart_defines=KEY=VALUE` appends environment declarations to every Dart compile, after any target-level `defines`. It is repeatable — one define per occurrence — so a `.bazelrc` config group can point a whole build at an environment without editing BUILD files, reaching binaries, tests, and web targets alike. On a key collision the flag wins, because every Dart compiler takes the last `-D` for a repeated key.

No define keys are reserved. rules_dart maps compilation mode to `--enable-asserts` and gen-snapshot options only, and sets no define of its own, so there is nothing for a user value to collide with. (rules_flutter reserves `dart.vm.product` and friends because its build does set them.)

One caveat, inherited from the Dart CLI and shared by the `defines` attribute: the VM front end (`dart compile exe|kernel`, `gen_kernel`) splits a define **value** on commas, so `-DA=x,y` yields `A=x`. `dart compile js` does not split. Values containing commas are therefore not portable across compile modes. The flag is declared `repeatable` so that Bazel itself never splits them — the limit is the compiler's, not the build system's.

---

## Testing

| Test Type             | Location                    | What                                                       |
| --------------------- | --------------------------- | ---------------------------------------------------------- |
| Starlark unit tests   | `dart/tests/`               | versions.bzl, common.bzl (package_config), yaml_parser.bzl |
| Gazelle tests         | `dev/`                      | gazelle_generation_test + shell test                       |
| E2e integration tests | `e2e/*/`                    | Full build scenarios in isolated workspaces                |
| CI                    | `.github/workflows/ci.yaml` | All e2e folders on Bazel 9.x                               |
| BCR presubmit         | `.bcr/presubmit.yml`        | Multi-platform × Bazel 9.x                                 |
