"""Providers for Dart rules."""

# The upstream `code_assets` link-mode vocabulary, verbatim (see
# `code_assets/lib/src/code_assets/syntax.g.dart`). Declared here, next to the
# provider whose field carries it, so that consumers in other rule sets —
# rules_flutter builds its own bundling layer over `DartCodeAssetInfo` — share
# one definition rather than keeping a copy that can drift.
#
# `static` is deliberately absent: upstream reserves it, but neither the Dart
# VM nor the Flutter engine implements it (dart-lang/sdk#49418).
CODE_ASSET_LINK_MODES = (
    "dynamic_loading_bundle",
    "dynamic_loading_system",
    "dynamic_loading_executable",
    "dynamic_loading_process",
)

DartInfo = provider(
    doc = "Information about a Dart library's sources and transitive dependencies.",
    fields = {
        "package_name": "str: The Dart package name for this library.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent; consumers derive exec-root paths from source File objects.",
        "transitive_srcs": "depset[File]: All transitive Dart source files, including this library's own sources.",
        "transitive_packages": "depset[DartPackageInfo]: Package metadata for this library and all transitive deps.",
    },
)

DartPackageInfo = provider(
    doc = "Metadata about a single Dart package, carried in depsets within DartInfo.",
    fields = {
        "package_name": "str: The Dart package name. Required.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent. Required; empty string for the root package.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Optional; empty string when unknown.",
    },
)

DartPackageConfigInfo = provider(
    doc = "A generated `package_config.json` file that maps `package:` URIs to source locations.",
    fields = {
        "file": "File: The generated package_config.json.",
    },
)

DartCompileInfo = provider(
    doc = "Information about a compiled Dart output.",
    fields = {
        "executable": "File: The compiled output file.",
        "compile_mode": "str: The compilation mode used (`exe`, `aot-snapshot`, `kernel`, or `jit-snapshot`).",
    },
)

DartCodeAssetInfo = provider(
    doc = """A native code asset (a Bazel-built dynamic library) bound to the \
Dart `@Native`/`@DefaultAsset` asset id the owning package uses.

Produced by the `dart_code_asset` rule and consumed via the `code_assets` \
attribute of `dart_test` / `dart_binary`, which embed the mapping into the \
compiled kernel (`gen_kernel --native-assets`) so the Dart VM resolves the \
package's `@Native` symbols against the Bazel-built library at runtime.""",
    fields = {
        "asset_id": "str: The code-asset id the owning package declares (its `@ffi.DefaultAsset` / `@Native(assetId:)`), e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`.",
        "link_mode": "str: How the runtime loads the asset. One of `dynamic_loading_bundle`, `dynamic_loading_system`, `dynamic_loading_executable`, `dynamic_loading_process` — the upstream `code_assets` strings, verbatim.",
        "dynamic_library": "File or None: The dynamic library (`.so`/`.dylib`/`.dll`) the asset resolves to. Set only for `dynamic_loading_bundle`; `None` otherwise.",
        "system_uri": "str: System library URI (e.g. `libsqlite3.so.0`) for `dynamic_loading_system`. Empty string otherwise.",
    },
)
