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
    doc = """Information about a Dart library's sources and transitive dependencies.

Read this directly off any target that provides it. To *build* one, call \
`dart_info()` from `//dart:utils.bzl` rather than this constructor — or \
`dart_info_no_package()` when the target ships no Dart package and provides \
`DartInfo` only to satisfy a `deps` attribute requiring one. Either takes what \
a target contributes itself and merges every dependency's closure internally, \
so a field added here needs no change in the rule sets that produce `DartInfo` \
— rules_flutter and rules_dart_proto both do. Constructing it here means \
enumerating and merging each field by hand, and a field left empty rather than \
forwarded silently discards every dependency's values.""",
    fields = {
        "package_name": "str: The Dart package name for this library.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent; consumers derive exec-root paths from source File objects.",
        "transitive_srcs": "depset[File]: All transitive Dart source files, including this library's own sources.",
        "transitive_resources": "depset[File]: Non-Dart files shipped inside `lib/` (see `dart_library`'s `resources`) by this library and all transitive deps. Carried beside `transitive_srcs` rather than within it because the two are routed differently: everything that stages a whole package wants both, and nothing that feeds the compiler wants these.",
        "transitive_packages": "depset[DartPackageInfo]: Package metadata for this library and all transitive deps.",
        "transitive_code_asset_files": "depset[File]: The dynamic libraries of every transitive code asset. Carried separately from `transitive_packages` because a depset of providers cannot be turned back into files for runfiles.",
    },
)

DartPackageInfo = provider(
    doc = "Metadata about a single Dart package, carried in depsets within DartInfo.",
    fields = {
        "package_name": "str: The Dart package name. Required.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent. Required; empty string for the root package.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Optional; empty string when unknown.",
        "code_assets": "tuple[DartCodeAssetInfo]: Native code assets this package owns. A tuple rather than a list because `DartPackageInfo` is carried in a depset, whose elements must be hashable.",
        "has_unreplaced_hook": "str: Path of a `hook/build.dart`/`hook/link.dart` this package ships that has no Bazel replacement (empty when none). Recorded at repo generation; acted on by `dart_binary`/`dart_test`.",
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

DartAnalysisOptionsInfo = provider(
    doc = """An `analysis_options.yaml` together with the packages its \
`include:` directives resolve against.

A shared lint ruleset is published as a pub package and pulled in by \
`package:` URI, which the analyzer resolves through the staged project's \
`package_config.json`. So an options file can carry package dependencies, and \
the only alternative — adding the ruleset to the analyzed library's own `deps` \
— leaks a lint-only package into that library's `DartInfo`, and from there \
into every binary and test downstream of it.

Produced by `dart_analysis_options` and consumed by `dart_analyze_test`'s \
`options` attribute, which stages these packages for options resolution alone: \
they are resolvable from the project, never themselves analyzed, and never \
merged into the analyzed target's provider.""",
    fields = {
        "file": "File: The `analysis_options.yaml`.",
        "packages": "list[DartPackageInfo]: Package metadata for every package the includes may reference.",
        "transitive_srcs": "depset[File]: Dart sources of those packages.",
        "transitive_resources": "depset[File]: Non-Dart `lib/` files of those packages — where a published ruleset's yaml actually lives.",
    },
)
