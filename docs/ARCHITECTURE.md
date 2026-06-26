# rules_dart — Architecture & Design

## Overview

`rules_dart` is a Bazel rule set for the Dart language. It:

- Downloads published Dart SDK releases (not building from source)
- Uses bzlmod exclusively, targeting Bazel 9.x
- Is designed for future extension by a `rules_flutter` rule set

---

## Provider Design

| Provider                | Level        | Purpose                                                                |
| ----------------------- | ------------ | ---------------------------------------------------------------------- |
| `DartSdkInfo`           | Toolchain    | SDK binaries (`dart`, `dartaotruntime`), SDK root, version, tool_files |
| `DartInfo`              | Library      | Package name, lib_root, transitive_srcs, transitive_packages           |
| `DartPackageInfo`       | Metadata     | Single package's name + lib_root (carried in DartInfo depsets)         |
| `DartPackageConfigInfo` | Build action | Generated package_config.json file                                     |
| `DartCompileInfo`       | Binary       | Compiled output file, compile_mode string                              |

**DartInfo contains zero Flutter concepts.** A future `rules_flutter` wraps/extends, never modifies.

---

## Dart Compilation Model

Unlike Go/Rust, Dart does not produce intermediate object files for libraries. The compiler takes the full transitive source tree. Therefore:

- `dart_library` is **source-only** — it collects sources and propagates `DartInfo`
- Compilation happens in `dart_binary`, `dart_test`, `dart_js_binary`, `dart_wasm_binary`
- `package_config.json` is generated at build time from the transitive `DartInfo` graph to bridge Bazel's dep model with Dart's `package:` URI resolution

---

## Design Decisions

1. **Bazel version**: Bazel 9.x only. bzlmod required.
2. **Platforms**: macos-arm64, macos-x64, linux-x64, linux-arm64, windows-x64.
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
- **Cross toolchains** (8): `exec_compatible_with` = host, `target_compatible_with` = cross target
- **Exec-tools toolchains** (5): `exec_compatible_with` = host, `target_compatible_with` omitted — for the codegen rules (see [Toolchain Types](#toolchain-types))

When `--platforms` is set, Bazel's toolchain resolution picks the cross toolchain. `DartSdkInfo` carries `target_os`/`target_arch`, which `dart_compile_action` passes as `--target-os`/`--target-arch` flags.

### Supported Cross-Compilation Matrix

| Host (exec) | Target                 |
| ----------- | ---------------------- |
| macOS arm64 | linux-x64, linux-arm64 |
| macOS x64   | linux-x64, linux-arm64 |
| Linux x64   | linux-arm64            |
| Linux arm64 | linux-x64              |
| Windows x64 | linux-x64, linux-arm64 |

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

## Toolchain Types

rules_dart exposes **two** toolchain types, registered together by `dart_register_toolchains` (so `register_toolchains("@dart_toolchains//:all")` picks up both):

- **`//dart:toolchain_type`** — target-configuration. Used by the rules that produce target-platform artifacts: `dart_binary`, `dart_test`, `dart_js_binary`, `dart_wasm_binary`, plus the analyze/format test rules. Registered native (exec == target) and cross (exec = host, target = cross target) — so resolution depends on the build's target platform, which is correct for compilation.

- **`//dart:exec_tools_toolchain_type`** — exec-configuration. Used only by the build-time code generators: `dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen`. These run a generator on the exec/host machine and emit **platform-agnostic Dart source**, so SDK selection must not depend on the target platform. Its toolchains are registered one per host platform with `exec_compatible_with` pinned and **`target_compatible_with` omitted**, so each matches *any* target platform. Both types reuse the same native `dart_toolchain` (the host SDK) — there is no separate SDK download.

This split is why codegen resolves even under a target platform rules_dart registers no compile toolchain for — e.g. a downstream Flutter build that puts the whole graph on `@platforms//os:ios` or `:android`. Were codegen on `//dart:toolchain_type`, it would fail with "No matching toolchains found" for those targets even though the generator runs fine on the host. (Regression-guarded by `e2e/codegen/foreign_platform`, which builds a codegen target under a synthetic toolchain-less platform.)

> Migration note: modules that register via the `@dart_toolchains//:all` glob get both types automatically. A module that instead hand-registers *specific* dart toolchains must also register the `*_exec_tools_toolchain` targets, or codegen will fail to resolve.

---

## Compilation Modes

Bazel's `-c` flag (`fastbuild`, `dbg`, `opt`) controls compiler flags automatically. Rules read `ctx.var["COMPILATION_MODE"]` and map it to Dart compiler flags. Per-target overrides are available via `dart_compile_flags` and `defines` attributes on all compilation rules.

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
- **`defines`** (`string_list`): Entries in `key=value` format. Each becomes a `-Dkey=value` flag passed to the compiler.

---

## Testing

| Test Type             | Location                    | What                                                       |
| --------------------- | --------------------------- | ---------------------------------------------------------- |
| Starlark unit tests   | `dart/tests/`               | versions.bzl, common.bzl (package_config), yaml_parser.bzl |
| Gazelle tests         | `dev/`                      | gazelle_generation_test + shell test                       |
| E2e integration tests | `e2e/*/`                    | Full build scenarios in isolated workspaces                |
| CI                    | `.github/workflows/ci.yaml` | All e2e folders on Bazel 9.x                               |
| BCR presubmit         | `.bcr/presubmit.yml`        | Multi-platform × Bazel 9.x                                 |
