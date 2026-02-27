# rules_dart — Architecture & Design

## Overview

`rules_dart` is a Bazel rule set for the Dart language. It:

- Downloads published Dart SDK releases (not building from source)
- Uses bzlmod exclusively, targeting Bazel 9.x
- Is designed for future extension by a `rules_flutter` rule set

---

## Directory Structure

```
rules_dart/
  MODULE.bazel                     # module: rules_dart
  dart/
    BUILD.bazel                    # toolchain_type, resolved_toolchain
    defs.bzl                       # Public API (7 rules)
    providers.bzl                  # DartInfo, DartPackageInfo, DartPackageConfigInfo, DartCompileInfo
    toolchain.bzl                  # DartSdkInfo provider, dart_toolchain rule
    extensions.bzl                 # dart.toolchain(dart_version = "3.11.1")
    repositories.bzl               # SDK download, dart_register_toolchains
    private/
      versions.bzl                 # SDK_VERSIONS with SHA-256 hashes per platform
      toolchains_repo.bzl          # PLATFORMS: macos-arm64, macos-x64, linux-x64, linux-arm64, windows-x64
      resolved_toolchain.bzl       # Resolved toolchain alias
      dart_sdk_binary.bzl          # Exposes Dart SDK as runnable target (bazel run @rules_dart//dart)
      dart_library.bzl             # dart_library: source collection, DartInfo propagation
      dart_binary.bzl              # dart_binary: compilation via dart compile (4 modes)
      dart_compile.bzl             # Shared compilation action helpers
      dart_test.bzl                # dart_test: test execution via Dart VM
      dart_analyze.bzl             # dart_analyze_test: static analysis as build-time action
      dart_format_test.bzl         # dart_format_test: format checking
      dart_web_application.bzl     # dart_js_binary, dart_wasm_binary: JS/WASM compilation
      package_config.bzl           # Standalone package_config.json generation rule
      common.bzl                   # Shared utilities
    tests/                         # Starlark unit tests (versions, package_config, yaml_parser)
    pub/
      defs.bzl                     # Reserved for future pub rules
      extensions.bzl               # pub.package() and pub.from_lock() module extensions
      private/
        pub_repository.bzl         # Single pub.dev package repository rule
        pub_lock_package.bzl       # Single spoke repo for one lock file package
        pub_lock_hub.bzl           # Hub repo with aliases to spoke repos
        yaml_parser.bzl            # Minimal YAML subset parser
  gazelle/
    dart/                          # Gazelle language plugin (Go)
  dev/                             # Gazelle tests + testdata
  e2e/                             # Integration tests (smoke, hello_world, library_deps, dart_test,
                                   #   analysis, web_app, pub_deps, pub_lock, gazelle, cross_compile)
```

---

## Provider Design

| Provider | Level | Purpose |
|----------|-------|---------|
| `DartSdkInfo` | Toolchain | SDK binaries (`dart`, `dartaotruntime`), SDK root, version, tool_files |
| `DartInfo` | Library | Package name, lib_root, transitive_srcs, transitive_packages |
| `DartPackageInfo` | Metadata | Single package's name + lib_root (carried in DartInfo depsets) |
| `DartPackageConfigInfo` | Build action | Generated package_config.json file |
| `DartCompileInfo` | Binary | Compiled output file, compile_mode string |

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
5. **Gazelle plugin**: `rules_go` and `gazelle` are non-dev dependencies so `//gazelle/dart` is loadable from downstream modules. See the comment in `MODULE.bazel` for the full rationale. The Go SDK is only fetched if a target in `//gazelle/...` is actually built.

---

## Cross-Compilation

Dart's AOT compiler supports cross-compilation via `--target-os` and `--target-arch` flags on `dart compile exe` and `dart compile aot-snapshot`. No separate SDK is needed — the host SDK can produce binaries for other platforms.

### How It Works

Each SDK repository generates both a **native** `dart_toolchain` target (no `target_os`/`target_arch`) and **cross** `dart_toolchain_cross_{target}` targets for each supported cross-compilation pair. The toolchains repository registers:

- **Native toolchains** (5): `exec_compatible_with` and `target_compatible_with` match the same platform
- **Cross toolchains** (8): `exec_compatible_with` = host, `target_compatible_with` = cross target

When `--platforms` is set, Bazel's toolchain resolution picks the cross toolchain. `DartSdkInfo` carries `target_os`/`target_arch`, which `dart_compile_action` passes as `--target-os`/`--target-arch` flags.

### Supported Cross-Compilation Matrix

| Host (exec) | Target |
|-------------|--------|
| macOS arm64 | linux-x64, linux-arm64 |
| macOS x64 | linux-x64, linux-arm64 |
| Linux x64 | linux-arm64 |
| Linux arm64 | linux-x64 |
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

---

## Testing

| Test Type | Location | What |
|-----------|----------|------|
| Starlark unit tests | `dart/tests/` | versions.bzl, common.bzl (package_config), yaml_parser.bzl |
| Gazelle tests | `dev/` | gazelle_generation_test + shell test |
| E2e integration tests | `e2e/*/` | Full build scenarios in isolated workspaces |
| CI | `.github/workflows/ci.yaml` | All e2e folders on Bazel 9.x |
| BCR presubmit | `.bcr/presubmit.yml` | Multi-platform × Bazel 9.x |
