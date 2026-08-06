# rules_dart — Architecture & Design

## Overview

`rules_dart` is a Bazel rule set for the Dart language. It:

- Downloads published Dart SDK releases (not building from source)
- Uses bzlmod exclusively, targeting Bazel 9.x
- Is designed for future extension by a `rules_flutter` rule set

---

## Provider Design

| Provider                | Level        | Purpose                                                                            |
| ----------------------- | ------------ | ---------------------------------------------------------------------------------- |
| `DartSdkInfo`           | Toolchain    | SDK binaries (`dart`, `dartaotruntime`), SDK root, version, tool_files             |
| `DartInfo`              | Library      | Package name, lib_root, transitive_srcs, transitive_resources, transitive_packages |
| `DartPackageInfo`       | Metadata     | Single package's name + lib_root (carried in DartInfo depsets)                     |
| `DartPackageConfigInfo` | Build action | Generated package_config.json file                                                 |
| `DartCompileInfo`       | Binary       | Compiled output file, compile_mode string                                          |

**DartInfo contains zero Flutter concepts.** A future `rules_flutter` wraps/extends, never modifies.

**Read `DartInfo` directly; build it through `dart_info()`** (`//dart:utils.bzl`). Rule sets outside rules_dart produce `DartInfo` too — `rules_flutter`'s `flutter_library`, `rules_dart_proto`'s `dart_proto_library` — and constructing it by hand means enumerating every field and merging every transitive depset one at a time. That made each added field a breaking change for all of them, and left each to work out independently how the new field merges. `dart_info()` takes what a target contributes itself and merges its dependencies' closures internally, so a new field is a change to one function. It also removes a failure that is invisible in review: a missing field's correct fix (forward the dependencies' values) and its tempting fix (declare it `depset()`) look identical in a diff, and the second silently drops every dependency's contribution at that boundary. A provider that deliberately carries no package of its own — `flutter_material_icons` ships a font and no Dart — has nothing to merge and constructs `DartInfo` directly.

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

- **`//dart:toolchain_type`** — target-configuration. Used by the rules that produce target-platform artifacts: `dart_binary`, `dart_test`, `dart_js_binary`, `dart_wasm_binary`, plus the analyze/format test rules. Registered native (exec == target) and cross (exec = host, target = cross target) — so resolution depends on the build's target platform, which is correct for compilation.

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
