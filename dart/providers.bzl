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
        "packages": "tuple[DartPackageInfo]: The packages this target contributes itself, also found in `transitive_packages`. One for a library; none for a target built by `dart_info_no_package()`; several for a library over packages that depend on each other (pub allows a dependency cycle, Bazel does not), each keeping its own name and `package_root`.",
        "srcs": "list[File]: This target's own Dart sources (or its source directory), without its dependencies', whichever of its `packages` they belong to. The unit a per-library kernel compile builds.",
        "deps": "dict[Label, tuple[str]]: The targets this one depends on directly, as passed to `dart_info()` from whatever attribute or toolchain they came, each with the names of the packages it contributes (its `packages`). The modules a per-library compile builds against, and the packages it may import.",
        "indirect_deps": "list[Label]: Targets one of `deps` depends on that this target's sources import, which the layering check accepts as direct. See `dart_info()`.",
        "transitive_srcs": "depset[File]: All transitive Dart source files, including this library's own sources.",
        "transitive_src_dirs": "depset[File]: The directories (tree artifacts or source directories) among `transitive_srcs`. An action that lists a directory's files must declare it; one that only names a source by path need not declare the file, so an edit to its body does not rerun the action. Optional on providers built before it existed.",
        "transitive_resources": "depset[File]: Non-Dart files shipped inside `lib/` (see `dart_library`'s `resources`) by this library and all transitive deps. Carried beside `transitive_srcs` rather than within it because the two are routed differently: everything that stages a whole package wants both, and nothing that feeds the compiler wants these.",
        "transitive_packages": "depset[DartPackageInfo]: Package records for this library and all transitive deps.",
        "transitive_code_asset_files": "depset[File]: The dynamic libraries of every transitive code asset. Carried separately from `transitive_packages` because a depset of providers cannot be turned back into files for runfiles.",
        "summaries": "struct: The analyzer summaries analysis against summaries (`--@rules_dart//dart:analysis_summaries`) reads, declared by `dart_info()` and built only when an analysis reads them: `transitive` (depset[File]: this target's summary and every one it depends on, what a dependent reads), `deps` (depset[File]: those of its dependencies alone, what its own files are analyzed against), `sdk` (File or None: the SDK summary a `sky_engine` it reaches makes with its `_embedder.yaml`; None for the SDK's own), `sdk_owner` (Label or None: that `sky_engine`) and `error` (str or None: why analysis against summaries cannot read them, reported by an analysis that needs them). Absent from a provider built by hand, whose dependents' analysis against summaries fails.",
    },
)

DartPackageMetadataInfo = provider(
    doc = """A Dart package's own facts, declared once: the Bazel stand-in for its \
`pubspec.yaml`, made by `dart_package_metadata`.

Distinct from `DartPackageInfo`, which is a *record of a package in the build \
graph*, accumulated by `dart_info()` and carried in depsets. This is the \
*declaration* every target of the package names with `package`, so a fact is \
stated in one place and every record of the package carries it, whichever of \
its targets a program reaches. Build a record from it with \
`package_info_from_metadata()`.

Its location is the package root, as a pubspec's directory is: an executable \
naming it belongs to the package wherever its own BUILD file sits.

Deliberately a leaf: it carries no `DartInfo`, so a `dart_package_metadata` \
cannot be mistaken for a dependency. `attr.label(providers = ...)` is \
require-only, and a target providing `DartInfo` would make \
`dart_library(deps = [":pkg"])` legal with nothing to say about it.

A codegen rule returns the declaration it was built for, or, when it names \
none, one with only the package name (`label` `None`), so the library \
collecting its output can check that both name the same package.""",
    fields = {
        "label": "Label or None: The `dart_package_metadata` target. `None` on the provider a codegen rule naming no declaration returns.",
        "package_name": "str: The Dart package name used in `package:` imports. Required.",
        "package_root": "str: The package root's short_path: the directory of the declaring BUILD file, which is at the root. Empty for the main repository's root.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Empty when the package states none.",
        "version": "str: The package's own resolved version; empty when unknown, as for a hand-written package.",
        "code_assets": "tuple[DartCodeAssetInfo]: Native code assets the package owns.",
        "unreplaced_hook": "str: `hook/build.dart` when the package has a build hook and no `code_assets` replace it; empty otherwise.",
        "link_hook": "File or None: The package's `hook/link.dart`.",
        "license_file": "File or None: The package's license text.",
    },
)

DartPackageInfo = provider(
    doc = "Record of a single Dart package in the build graph, carried in depsets within DartInfo.",
    fields = {
        "label": "Label or None: The target that stated this record — for a merged record, the first of the targets whose records were merged. Read only for error messages, which name the targets whose statements disagree. Optional; absent from a record built by a producer predating the field.",
        "package_name": "str: The Dart package name. Required.",
        "package_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent. Required; empty string for the root package.",
        "version": "str: The package's own version, as resolved by pub (e.g. `2.2.0`). Optional; empty string when unknown, which is what a `dart_library` written by hand and a producer predating this field both carry. Recorded so that two records for one package name can be checked for agreement — see `package_agreement_error`.",
        "language_version": "str: Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form. Optional; empty string when unknown.",
        "code_assets": "tuple[DartCodeAssetInfo]: Native code assets this package owns. A tuple rather than a list because `DartPackageInfo` is carried in a depset, whose elements must be hashable.",
        "unreplaced_hook": "str: Path of a `hook/build.dart` this package ships that has no Bazel replacement (empty when none). Merged across a package's records: unreplaced when any states one and none has `code_assets`. Acted on by `dart_binary`/`dart_test`.",
        "link_hook": "File or None: The package's `hook/link.dart`, which `dart_link_hook` runs. Optional; `None` when the package has none, and absent from a record built by a producer predating the field.",
        "license_file": "File or None: The package's license text — for a pub package, the `NOTICES` file at its root if it has one, else its `LICENSE`, the file `flutter build` collects for the license page. Optional; `None` when the package has none, and absent from a record built by a producer predating the field. Read it with `package_license_file()` from `//dart:utils.bzl`.",
        "metadata": "Label or None: The `dart_package_metadata` the record was built from (`package_info_from_metadata()`), or `None` for a package that names none. Records of one package rooted at one directory must name the same one. Optional; absent from a record built by a producer predating the field.",
    },
)

DartAnalyzableInfo = provider(
    doc = """An executable target's analyzable closure: everything \
the `dart_analyze` aspect needs to stage a project around its entrypoint.

Provided by executable rules — `dart_binary`, `dart_test`, `dart_js_binary`, \
`dart_wasm_binary` here, and downstream by rules whose target is an executable \
that *also* contributes a package (a `flutter_test` whose `srcs` are its own \
package's `lib/` files). The executables here contribute one too when they \
name a `package`. A library needs nothing extra: for it `DartInfo` *is* \
the analyzable closure, and the aspect accepts either provider, which is what \
keeps `dart_proto_library` analyzable without adopting anything. The aspect \
checks a target's own files: its `DefaultInfo` `.dart` files (a library's \
sources), its nested `DartInfo.srcs` and this provider's `entry_srcs`.

The separation is what makes an entrypoint analyzable without making it a valid \
dependency. Every `deps` attribute in this rule set and downstream ones gates on \
`providers = [DartInfo]`, so an executable returning `DartInfo` would make \
`dart_library(deps = [":some_binary"])` legal — and Bazel has no way to express \
"provides it but is not a dep", `attr.label(providers = ...)` being require-only. \
A distinct outer provider that *nests* the `DartInfo` says the same thing \
structurally: consumable by whoever asks for it, invisible to whoever asks for \
`DartInfo`.

Build one with either constructor in `//dart:utils.bzl`, never by hand. \
`dart_analyzable_info()` takes `dart_info()`'s arguments and builds the nested \
`DartInfo` through it, for a target whose sources *are* packages: without their \
records its own `package:<self>/…` imports resolve against nothing and every \
one of them reports `uri_does_not_exist`. `dart_analyzable_info_no_package()` \
takes `dart_info_no_package()`'s and builds it through that, for an entrypoint \
that contributes no package — under pub it belongs to the root package but sits \
outside its `lib/`.""",
    fields = {
        "dart_info": "DartInfo: the dependency closure, as the `dart_analyzable_info*()` constructors build it — package-less, or carrying this target's own package records. Its `srcs` are the target's own `lib/` files, which a target's `DefaultInfo` (a web bundle, a test executable) need not list.",
        "entry_srcs": "depset[File]: the target's own sources that belong to no package's `lib/` — its `main`, a `test/` entrypoint — and which therefore no `DartPackageInfo` can name. Sources that *are* a package's `lib/` files ride the nested `DartInfo` instead.",
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
        "compile_mode": "str: The compilation mode used (`exe`, `aot-snapshot` or `kernel`).",
    },
)

DartCodeAssetInfo = provider(
    doc = """A native code asset (a Bazel-built dynamic library) bound to the \
Dart `@Native`/`@DefaultAsset` asset id the owning package uses.

Produced by the `dart_code_asset` rule and consumed via the `code_assets` \
attribute of `dart_test` / `dart_binary`, which embed the mapping into the \
compiled kernel (`frontend_server --native-assets`) so the Dart VM resolves the \
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
        "kind": "str: `aot` when the compiler recorded the uses — the `exe` and `aot-snapshot` modes, whose tree-shaking is what makes the set of uses known — or `empty` for the `kernel` mode, which records nothing; their file is the empty JSON object the compiler writes when there is nothing to record.",
        "package": "Label or None: the `dart_package_metadata` of the program's own package (its `package`), which a `dart_link_hook` over these uses must name too.",
        "package_files": "list[File]: The program's own files under its package's `lib/`, which that package's link hook may import; what `dart_link_hook_actions` takes as `package_files`.",
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
(for the `dart_analyze` aspect), which stages these packages for options resolution alone: \
they are resolvable from the project, never themselves analyzed, and never \
merged into the analyzed target's provider.""",
    fields = {
        "file": "File: The `analysis_options.yaml`.",
        "packages": "list[DartPackageInfo]: Package records for every package the includes may reference.",
        "transitive_srcs": "depset[File]: Dart sources of those packages.",
        "transitive_resources": "depset[File]: Non-Dart `lib/` files of those packages — where a published ruleset's yaml actually lives.",
    },
)

DartKernelSdkInfo = provider(
    doc = """The compiler and platform one kernel target compiles with: for \
`dart_module_aspect`, and for `dart_whole_program_kernel_action`.

A kernel is only valid for the platform it was compiled against, so the VM \
(rules_dart) and Flutter (rules_flutter) each supply one of these. Everything \
that differs between the two is here; the compiles are otherwise the same \
code. A rule set or a user with a Dart SDK or engine of their own (a fork, a \
local build) fills it from that SDK's files, typically from the toolchain \
that SDK is registered as, so nothing about which SDK compiles is fixed in \
rules_dart.

A platform has one platform `.dill` per kind of runtime it runs on: the VM \
has a product runtime, Flutter a debug, a profile and a release \
one. `runtimes` names each, and a compile asks for one by its name.""",
    fields = {
        "target": "str: The front end's target name (`vm`, `flutter`).",
        "aot_runtime": "File: The `dartaotruntime` that runs the snapshots.",
        "kernel_worker": "File or None: `kernel_worker_aot.dart.snapshot`, which compiles modules. None for a platform that compiles whole programs only.",
        "frontend_server": "File: `frontend_server_aot.dart.snapshot`, which compiles an executable's entrypoint and whole programs.",
        "runtimes": "dict[str, struct]: The kinds of runtime a kernel can be compiled for, by name (`product` for the VM), each made by `dart_kernel_runtime()`: the platform `.dill` a kernel for that runtime compiles against, in whose directory the front end finds the SDK; the environment declarations that runtime fixes, e.g. `dart.vm.product=true`; and the front-end flags a whole-program compile for it takes.",
        "module_runtime": "str: The entry of `runtimes` that modules, and the entrypoints linked with them, compile for.",
        "libraries_spec": "File or None: The `libraries.json` that lists the `dart:` libraries `target` provides, which modules are split by. None for a platform that compiles whole programs only.",
        "libraries_target": "str: The entry in `libraries_spec` to read (its `include` entries are followed).",
        "tool_files": "depset[File]: What the tools read at run time beyond the files named above; the actions take nothing else of the SDK. Empty for the VM, whose front end reads only its snapshot, its runtime and the platform.",
        "outline_tool": "FilesToRunProvider or None: Writes the outlines dependents compile against (`outline_tool [--load <dill>]... [--module <dill> --outline <dill>]...`, or the same in an `@paramsfile`, one per line), run by the module action. It must be built on the `pkg/kernel` of the same SDK as `kernel_worker`, whose kernel format alone it reads: a `dart_kernel_source` repository's `:outline_tool` for a released Dart SDK. None, or unset, compiles them against full modules.",
    },
)

DartModuleInfo = provider(
    doc = """A target's compiled kernel modules and those of everything it \
depends on, from `dart_module_aspect`.

A target's sources are split as Dart's own modular build splits a package — \
one module per strongly connected component of their imports — and compiled into a directory of `.dill`s beside a \
`<directory>.json` manifest naming each module's libraries, its imports, and \
whether it compiled. An executable compiles its entrypoint against, and links, \
only the modules it reaches.

Modules compile against their dependencies' `outlines`, which an edit inside a \
function body leaves unchanged; only the link reads the full `modules`.""",
    fields = {
        "modules": "depset[File]: This target's module directory and every dependency's, dependencies first.",
        "outlines": "depset[File]: What dependents compile against, one directory per directory in `modules`, with the same files: `<directory>.outlines`, the modules without their function bodies, when the kernel SDK has an `outline_tool`; else the module directories themselves.",
        "manifests": "depset[File]: The `<directory>.json` manifest of each directory in `modules`.",
        "exported": "dict[Label, Target]: On a target that is not a library (a toolchain), the libraries it holds, for a library that names one in `DartInfo.deps`. Empty on a library.",
        "defines": "list[str]: The environment declarations (`KEY=VALUE`) of this target's configuration, which its modules were compiled in, the platform's aside. An executable's entrypoint must be compiled in the same.",
    },
)

DartImportCheckInfo = provider(
    doc = """The import checks of a target and everything it depends on, from \
`dart_import_check_aspect`.

Each library of this repository is checked once — its imports against its \
own `deps` (strict deps, files of its own package, and, unless the \
`dart_layering_check` feature is off, layering) — by a validation action \
that compiles nothing. An executable puts `stamps` in its `_validation` output \
group, so building it runs every check its libraries need.""",
    fields = {
        "stamps": "depset[File]: The check results of this target and its dependencies.",
        "exported": "dict[Label, Target]: On a target that is not a library (a toolchain), the libraries it holds, for a library that names one in `DartInfo.deps`. Empty on a library.",
    },
)
