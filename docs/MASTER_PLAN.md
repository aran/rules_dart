# Master Plan: rules_dart — A Production-Grade Bazel Rule Set for Dart

## Context

We are building `rules_dart`, an open-source Bazel rule set for the Dart language, starting from the bazel-contrib rules template (already cloned). The goal is a high-quality, maintainable rule set that:

- Downloads published Dart SDK releases (not building from source)
- Follows best practices from rules_go, rules_rust, rules_python
- Is heavily automated and test-driven for minimal human maintenance
- Supports future extension by a `rules_flutter` rule set
- Uses bzlmod (modern Bazel module system)

The template already provides: toolchain architecture, module extension, CI/CD workflows, e2e smoke test, pre-commit hooks, BCR publishing, and Renovate bot. All use "mylang" placeholders.

---

## Architecture Overview

### Target Directory Structure

```
rules_dart/
  MODULE.bazel                     # module: rules_dart
  dart/
    BUILD.bazel                    # toolchain_type, resolved_toolchain
    defs.bzl                       # Public API (dart_library, dart_binary, dart_test, etc.)
    providers.bzl                  # DartInfo, DartCompileInfo, DartPackageConfigInfo
    toolchain.bzl                  # DartSdkInfo provider, dart_toolchain rule
    extensions.bzl                 # dart.toolchain(dart_version = "3.6.1")
    repositories.bzl               # SDK download, dart_register_toolchains
    private/
      versions.bzl                 # SDK_VERSIONS with integrity hashes per platform
      toolchains_repo.bzl          # PLATFORMS mapping (macos-x64, macos-arm64, linux-x64, linux-arm64, windows-x64)
      resolved_toolchain.bzl       # Resolved toolchain alias
      dart_library.bzl             # dart_library implementation
      dart_binary.bzl              # dart_binary implementation
      dart_test.bzl                # dart_test implementation
      dart_compile.bzl             # Shared compilation action helpers
      dart_analyze.bzl             # dart_analyze implementation
      package_config.bzl           # package_config.json generation
      common.bzl                   # Shared utilities
    tests/                         # Starlark unit tests
  dart/pub/
    extensions.bzl                 # pub.package() and pub.from_lock() module extensions
    defs.bzl                       # Public pub API
    private/
      pub_repository.bzl           # Single package repository rule
      pub_lock_repository.bzl      # Lock file parser + BUILD generator
  e2e/
    smoke/                         # Toolchain resolution test
    hello_world/                   # dart_binary "Hello World"
    library_deps/                  # Transitive dart_library deps
    pub_deps/                      # External pub.dev packages
    dart_test/                     # dart_test integration
    analysis/                      # dart_analyze integration
    web_app/                       # dart compile js
```

### Provider Design

| Provider | Level | Purpose | Flutter Compatibility |
|----------|-------|---------|-----------------------|
| `DartSdkInfo` | Toolchain | SDK binaries, version, paths | Flutter registers its own with bundled SDK |
| `DartInfo` | Library | Sources, transitive deps, package name | Flutter libraries produce DartInfo too |
| `DartCompileInfo` | Binary | Compiled output, compile mode | Flutter adds FlutterInfo alongside |
| `DartPackageConfigInfo` | Build action | package_config.json for import resolution | Same format for Flutter |

Key principle: **DartInfo contains zero Flutter concepts.** Flutter wraps/extends, never modifies.

### Dart SDK Distribution

- URL: `https://storage.googleapis.com/dart-archive/channels/{channel}/release/{version}/sdk/dartsdk-{platform}-release.zip`
- Platforms: `macos-x64`, `macos-arm64`, `linux-x64`, `linux-arm64`, `windows-x64`
- Archive contains `dart-sdk/` with `bin/` (dart, dartaotruntime) and `lib/` (standard libraries)
- Channels: stable (default), beta, dev

### Core Design Decision: Dart Compilation Model

Unlike Go/Rust, Dart does not produce intermediate object files for libraries. The compiler takes the full transitive source tree. Therefore:
- `dart_library` is **source-only** — it collects sources and propagates `DartInfo`
- Compilation happens in `dart_binary`, `dart_test`, `dart_web_application`
- `package_config.json` is generated at build time from the transitive `DartInfo` graph to bridge Bazel's dep model with Dart's `package:` URI resolution

---

## Phased Implementation Plan

### Phase 1: Foundation — Template Transformation + SDK Toolchain ✅

**Goal**: Rename all `mylang` → `dart`, wire up Dart SDK download, verify toolchain resolves.

**Work items**:
0. Save this master plan to `docs/MASTER_PLAN.md` in the repository and clone reference repos into `/references/` (gitignored)
1. Rename `mylang/` directory to `dart/`
2. Update `MODULE.bazel`: module name → `rules_dart`, extension paths
3. Adapt `dart/private/versions.bzl`: populate with latest stable Dart SDK version + SHA256 hash for all platforms
4. Adapt `dart/private/toolchains_repo.bzl`: PLATFORMS mapping for all Dart SDK platform strings
5. Adapt `dart/repositories.bzl`: Dart SDK download URL pattern, `stripPrefix = "dart-sdk"`
6. Adapt `dart/toolchain.bzl`: `DartSdkInfo` provider exposing dart binary, SDK root, version
7. Adapt `dart/extensions.bzl`: `dart.toolchain(dart_version = "...")` tag class
8. Update `e2e/smoke/` to verify Dart toolchain resolution
9. Update all CI, BCR, and metadata references
10. Starlark unit tests for versions.bzl

**Validation**: `bazel build //...` passes. `bazel test //dart/tests/...` passes. e2e/smoke downloads Dart SDK.

### Phase 2: Core Rules — dart_library + dart_binary (with dart compile exe)

**Goal**: Build and run a native Dart executable with library dependencies using `dart compile exe`.

**Work items**:
1. Create `dart/providers.bzl` with `DartInfo`, `DartPackageConfigInfo`, `DartCompileInfo`
2. Implement `dart/private/dart_library.bzl` — source collection, DartInfo propagation
3. Implement `dart/private/package_config.bzl` — generate package_config.json from DartInfo graph
4. Implement `dart/private/dart_compile.bzl` — shared compilation action helpers (designed for multiple modes, only exe implemented initially)
5. Implement `dart/private/dart_binary.bzl` — using `dart compile exe`, with `compile_mode` attribute (default "exe", other modes stubbed)
6. Export rules from `dart/defs.bzl`
7. Create `e2e/hello_world/` — simple dart_binary producing native executable
8. Create `e2e/library_deps/` — dart_library + dart_binary with transitive deps
9. Starlark unit tests for package_config generation

**Key implementation detail**: `dart compile exe` requires:
- All transitive sources accessible in a layout matching Dart's expectations
- A `package_config.json` with root URIs pointing to correct source locations
- Command: `dart compile exe --packages=<package_config.json> -o <output> <main.dart>`
- The action must stage sources into a tree structure and generate package_config.json with relative URIs

**Validation**: `bazel run //e2e/hello_world:hello` produces and runs a native executable printing "Hello, World!". `bazel build //e2e/library_deps:app` produces a native executable with transitive library deps.

### Phase 3: Testing, Analysis, Additional Compile Modes + Basic Pub

**Goal**: Test execution, static analysis, additional compile modes, and manual pub dependency declaration.

**Work items**:
1. Add remaining compile modes to `dart_compile.bzl` and `dart_binary` (aot-snapshot, kernel, jit-snapshot)
2. Implement `dart/private/dart_test.bzl` — run tests via `dart test`
4. Implement `dart/private/dart_analyze.bzl` — analysis as test target
5. Implement `dart/private/dart_format_test.bzl` — format checking as test target
6. Implement `dart/pub/private/pub_repository.bzl` — download single pub package, generate BUILD
7. Implement `dart/pub/extensions.bzl` — `pub.package(name, version, sha256)` module extension
8. Create e2e tests: `pub_deps/`, `dart_test/`, `analysis/`
9. Implement `dart/private/dart_web_application.bzl` — `dart compile js` / `dart compile wasm`
10. Create `e2e/web_app/`

**Validation**: `bazel run :app` produces native executable. `bazel test :my_test` runs Dart tests. `bazel test :analyze` catches errors. External pub packages work.

### Phase 4: Pub Universe — pubspec.lock Integration

**Goal**: Automatically generate all dependency targets from pubspec.lock.

**Work items**:
1. Implement Starlark YAML-subset parser for pubspec.lock format
2. Implement `dart/pub/private/pub_lock_repository.bzl` — parse lock file, download all packages, generate BUILD files with correct dep graph
3. Add `pub.from_lock(lock_file, pubspec)` tag class to module extension
4. Determine inter-package deps by reading each downloaded package's pubspec.yaml
5. Create `e2e/pub_lock/` with a real-world pubspec.lock
6. Handle hosted, git, path, and sdk dependency sources

**Validation**: `pub.from_lock()` resolves all packages from pubspec.lock. Projects with non-trivial dependency graphs build correctly.

### Phase 5: Gazelle Plugin + Polish

**Goal**: Auto-generate BUILD files for Dart projects.

**Work items**:
1. Implement Gazelle plugin in Go (`dart/gazelle/`)
2. Parse Dart imports to determine dependencies
3. Generate dart_library (lib/), dart_binary (bin/), dart_test (test/) targets
4. Handle package: import → Bazel label resolution
5. Recognize analysis_options.yaml → generate dart_analyze targets
6. User documentation, examples, error message polish

**Validation**: `bazel run //:gazelle` generates correct BUILD files for a multi-package Dart project.

### Phase 6: Advanced Features + Flutter Prep

**Goal**: Cross-compilation, multiple SDK versions, formalize Flutter extension API.

**Work items**:
1. Multiple Dart SDK versions in same workspace
2. Cross-compilation support (e.g., compile Linux binary on macOS)
3. Performance: incremental compilation with kernel snapshots
4. Document and stabilize the public API surface for rules_flutter
5. Create `rules_flutter` integration test demonstrating SDK override pattern

---

## Testing Strategy

| Test Type | Location | When | What |
|-----------|----------|------|------|
| Starlark unit tests | `dart/tests/` | Every phase | Internal logic: versions, package_config, providers |
| E2e integration tests | `e2e/*/` | Every phase | Full build scenarios in isolated workspaces |
| CI matrix | `.github/workflows/ci.yaml` | Every PR | Linux + macOS + Windows × Bazel 7.x + 8.x |
| BCR presubmit | `.bcr/presubmit.yml` | Before publish | Multi-platform validation |

Each e2e test is a self-contained Bazel workspace with its own MODULE.bazel using `local_path_override` for development.

---

## Reference Implementations

Key patterns to study when implementing each phase:

| Pattern | Reference | Key Files |
|---------|-----------|-----------|
| SDK download + toolchain | rules_go | `go/private/sdk.bzl`, `go/extensions.bzl` |
| Provider design | rules_go | `go/private/providers.bzl` (GoInfo, GoSDK) |
| Dep management from lock file | rules_rust | `crate_universe/extension.bzl`, `crate_universe/private/generate_utils.bzl` |
| pip_parse module extension | rules_python | `python/extensions/pip.bzl` |
| Gazelle plugin architecture | rules_python | `gazelle/README.md`, `gazelle/python/` |
| Dart-specific patterns | matanlurey/rules_dart | `dart/private/rules/dart_library.bzl`, `dart/extensions/pub.bzl` |

---

## Resolved Design Decisions

1. **Reference repos**: Clone locally into `/references/` (gitignored) for direct code search during implementation.
2. **Starting platform**: macOS arm64 (development machine). All code designed for multi-platform from day one — platform-specific logic isolated in `versions.bzl` and `toolchains_repo.bzl`. Remaining platforms added incrementally.
3. **Compilation approach**: Start with `dart compile exe` directly in Phase 2 (not interpreted mode). API designed to accommodate multiple compile modes (exe, aot-snapshot, kernel, jit-snapshot) from the start, even if only exe is implemented initially.
4. **Starting SDK version**: Latest stable Dart SDK at time of implementation.
