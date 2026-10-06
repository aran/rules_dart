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
        "transitive_packages": "depset[DartPackageInfo]: Package records for this library and all transitive deps.",
        "transitive_code_asset_files": "depset[File]: The dynamic libraries of every transitive code asset. Carried separately from `transitive_packages` because a depset of providers cannot be turned back into files for runfiles.",
    },
)

DartPackageMetadataInfo = provider(
    doc = """The two facts a Dart package states about itself: its name and the \
language version its sources are written against.

Distinct from `DartPackageInfo`, which is a *record of a package in the build \
graph* — where its sources live, what version pub resolved, what native assets \
it owns — accumulated by `dart_info()` and carried in depsets. This is the \
*declaration* a `dart_package_metadata` target makes, read back through an \
attribute by the rules that would otherwise each ask for the same two strings.

It exists because those two facts are properties of a package, not of a rule, \
and a package is routinely built by more than one rule: a `dart_codegen` \
generating part of it and the `dart_library` collecting the result must agree \
on both, and `sibling_aggregate_pkg` shows the two living in different BUILD \
files, where no macro can hold them together. A referenceable declaration can.

Deliberately a leaf: it carries no `DartInfo`, so a `dart_package_metadata` \
cannot be mistaken for a dependency. `attr.label(providers = ...)` is \
require-only, and a target providing `DartInfo` would make \
`dart_library(deps = [":pkg"])` legal with nothing to say about it — the same \
trap `DartAnalyzableInfo` exists to avoid.""",
    fields = {
        "package_name": "str: The Dart package name used in `package:` imports. Required.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Empty when the package states none.",
    },
)

DartPackageInfo = provider(
    doc = "Record of a single Dart package in the build graph, carried in depsets within DartInfo.",
    fields = {
        "package_name": "str: The Dart package name. Required.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent. Required; empty string for the root package.",
        "version": "str: The package's own version, as resolved by pub (e.g. `2.2.0`). Optional; empty string when unknown, which is what a `dart_library` written by hand and a producer predating this field both carry. Recorded so that two records for one package name can be checked for agreement — see `package_agreement_error`.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Optional; empty string when unknown.",
        "code_assets": "tuple[DartCodeAssetInfo]: Native code assets this package owns. A tuple rather than a list because `DartPackageInfo` is carried in a depset, whose elements must be hashable.",
        "has_unreplaced_hook": "str: Path of a `hook/build.dart` this package ships that has no Bazel replacement (empty when none). Recorded at repo generation; acted on by `dart_binary`/`dart_test`.",
        "link_hook": "File or None: The package's `hook/link.dart`, which `dart_link_hook` runs. Optional; `None` when the package has none, and absent from a record built by a producer predating the field.",
    },
)

DartAnalyzableInfo = provider(
    doc = """An executable target's analyzable closure: everything \
the `dart_analyze` aspect and `dart_fix` need to stage a project around its \
entrypoint.

Provided by executable rules — `dart_binary`, `dart_test`, `dart_js_binary`, \
`dart_wasm_binary` here, and downstream by rules whose target is an executable \
that *also* contributes a package (a `flutter_test` whose `srcs` are its own \
package's `lib/` files). The executables here contribute one too when they \
state a `package`, `package_name` or `language_version`. A library needs nothing extra: for it `DartInfo` *is* \
the analyzable closure, and the aspect accepts either provider, which is what \
keeps `dart_proto_library` analyzable without adopting anything. The aspect \
checks a target's own files: its `DefaultInfo` `.dart` files (a library's \
sources) plus this provider's `srcs`.

The separation is what makes an entrypoint analyzable without making it a valid \
dependency. Every `deps` attribute in this rule set and downstream ones gates on \
`providers = [DartInfo]`, so an executable returning `DartInfo` would make \
`dart_library(deps = [":some_binary"])` legal — and Bazel has no way to express \
"provides it but is not a dep", `attr.label(providers = ...)` being require-only. \
A distinct outer provider that *nests* the `DartInfo` says the same thing \
structurally: consumable by whoever asks for it, invisible to whoever asks for \
`DartInfo`.

Build one with either constructor in `//dart:utils.bzl`, never by hand. \
`dart_analyzable_info()` builds the nested `DartInfo` through \
`dart_info_no_package()`, for an entrypoint that contributes no package — under \
pub it belongs to the root package but sits outside its `lib/`. \
`dart_analyzable_info_with_package()` builds it through `dart_info()`, for a \
target whose sources *are* a package: without that record its own \
`package:<self>/…` imports resolve against nothing and every one of them \
reports `uri_does_not_exist`.""",
    fields = {
        "dart_info": "DartInfo: the dependency closure, as the `dart_analyzable_info*()` constructors build it — package-less, or carrying this target's own package record.",
        "srcs": "depset[File]: the target's own sources that belong to no package's `lib/` — its `main`, a `test/` entrypoint — and which therefore no `DartPackageInfo` can name. Sources that *are* a package's `lib/` files ride the nested `DartInfo` instead.",
        "package_srcs": "depset[File]: the target's own sources that *are* its package's `lib/` files — the ones `dart_analyzable_info_with_package()` was given; empty for a package-less target. Named separately because the nested `DartInfo` holds them only inside its transitive closure, beside every dependency's, and a target's `DefaultInfo` (a web bundle, a test executable) need not list its sources at all. Optional: a producer built against a rules_dart without the field omits it.",
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

DartRecordedUsesInfo = provider(
    doc = """The uses of `@RecordUse` definitions the compiler recorded while \
building an executable: which annotated classes were instantiated with which \
constant fields, which annotated static methods were called with which \
constant arguments.

Provided by a `dart_binary` with `record_use = True`, and read by \
`dart_link_hook`, which hands the file to each package's `hook/link.dart` as \
`LinkInput.recordedUses`. The file is the JSON the Dart compiler writes, \
unchanged.""",
    fields = {
        "file": "File: The recorded-uses JSON.",
        "kind": "str: `aot` when the compiler recorded the uses — the `exe` and `aot-snapshot` modes, whose tree-shaking is what makes the set of uses known — or `empty` for the `kernel` and `jit-snapshot` modes, which record nothing; their file is the empty JSON object the compiler writes when there is nothing to record.",
    },
)

DartDataAssetInfo = provider(
    doc = """Data assets: files a Dart program reads at run time by asset id, \
the counterpart of `DartCodeAssetInfo` for data rather than native code.

Produced by `dart_link_hook` from the data assets its link hooks emit. Carries \
only what upstream's `DataAsset` carries — package, name, file — and no \
bundling paths: where the file lands inside an application is the bundler's \
decision (rules_flutter's, for a Flutter app).""",
    fields = {
        "assets": "depset[struct]: One struct per data asset, with `package` (str: the owning package), `name` (str: the asset's name within the package, e.g. `glyphs/index.json`), `file` (File) and `id` (str: `package:<package>/<name>`, the id Dart code loads it by).",
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

Produced by `dart_analysis_options` and consumed by `dart_analysis_config` \
(for the `dart_analyze` aspect and `dart_format`), which stages these packages for options resolution alone: \
they are resolvable from the project, never themselves analyzed, and never \
merged into the analyzed target's provider.""",
    fields = {
        "file": "File: The `analysis_options.yaml`.",
        "packages": "list[DartPackageInfo]: Package records for every package the includes may reference.",
        "transitive_srcs": "depset[File]: Dart sources of those packages.",
        "transitive_resources": "depset[File]: Non-Dart `lib/` files of those packages — where a published ruleset's yaml actually lives.",
    },
)
