# rules_dart — Code Generation (`dart/ext/`)

## Goal

Run the `package:build` `Builder` ecosystem (`json_serializable`,
`freezed`, `built_value`, `mockito`, `copy_with_extension_gen`, `stacked`,
`drift`) under Bazel without `build_runner`.
Users write Dart with `@JsonSerializable`, `@freezed`, `@DriftDatabase`,
`@StackedApp`, etc., and Bazel produces the generated code as regular
build outputs.

## Why not `build_runner`

`build_runner` assumes a pub-package-rooted working tree, reads arbitrary
files, writes into `.dart_tool/`, and holds state across actions. That
model breaks three Bazel guarantees:

- **Hermeticity**: arbitrary file reads/writes leak sandbox state.
- **Caching**: whole-package actions can't cache per-input.
- **Parallelism**: one serial pipeline per package, no per-file fan-out.

The shim approach keeps Builder execution identical (same
`Builder.build(BuildStep)`, same analyzer, same `source_gen` machinery)
but wraps each Builder invocation as a single Bazel action with declared
inputs, declared outputs, and no side-effects outside `bazel-out`.

## Architecture

```
dart/ext/
├── lib/
│   ├── builder_shim.dart      Generic shim runner: arg parser, AssetReader,
│   │                          AssetWriter, Resolver (analyzer),
│   │                          BuildStep, package_config synthesis.
│   └── worker_entry.dart      AsyncWorkerLoop subclass; constructs a fresh
│                              AnalysisContext per request. `shimMain`
│                              dispatches worker vs one-shot.
├── _shared/
│   └── combining_shim/bin/    Concatenates SharedPart shards into one .g.dart,
│                              mirroring source_gen|combining_builder.
├── json_serializable/         One shim binary + convenience macro per builder.
├── freezed/
├── built_value/
├── mockito/
├── copy_with_extension_gen/
├── stacked/                   Six independent LibraryBuilders.
└── drift/                     Four-stage: prep + discover/analyzer/driftBuilder.
```

Every shim binary is a `dart_binary(compile_mode="exe")`. In worker mode
it reads `WorkRequest` protos from stdin and writes `WorkResponse` protos
to stdout; in one-shot mode it accepts a `@<flagfile>` argument and exits.

## Shim contract

All shim CLIs share this contract (`dart/ext/lib/builder_shim.dart:ShimArgs.parse`):

```
--input <exec-path>                      Primary input file.
--input-asset <lib-rel-path>             Asset path of --input within its owning
                                         package (preserves lib/src/...).
--output <path>                          Declared output file. Repeatable — one
                                         per declared Bazel output (for multi-
                                         output builders that emit both
                                         `.config.dart` and `.module.dart`).
--package <name>                         Owning Dart package name (required).
--root-language-version <major.minor>    Consumer's language version (required).
--dep <exec-path>|<asset-path>           Additional source visible to analyzer.
                                         Repeatable.
--input-asset-extra <exec-path>|<asset>  Aggregate mode: additional inputs
                                         (dart_aggregate_codegen only).
--part <path>                            SharedPart shard. Repeatable
                                         (combining_shim only).
--config <json-string>                   Builder options.
--package-config <path>                  Synthesised package_config.json with
                                         every third-party pub dep.
--sdk-path <dir>                         Dart SDK root for the analyzer.
[--persistent_worker]                    Switches to bazel_worker protocol.
```

Rule layer: `dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen`
in `dart/private/`. All three drive the same shim contract; they differ
in how they compose inputs/outputs:

- `dart_codegen(src, output_suffixes = [...])` — per-file; one action per
  target, one input, one-or-more outputs (one per suffix). The shim
  routes each builder-emitted asset to the declared Bazel output whose
  basename shares the input stem + the matching suffix.
- `dart_aggregate_codegen(srcs, outputs = [...])` — package-aggregate;
  one action sees every `src`, produces one-or-more declared outputs
  (user-specified paths, not suffix-derived).
- `dart_sqlcodegen(src, output_suffixes = [...])` — like `dart_codegen`
  but the input file extension is arbitrary (`.drift`, `.moor`).

### Builder options (`config`)

The `config` attribute on all three codegen rules (and the `config = "{...}"`
argument every builder macro forwards) is a JSON **object** string, passed to
the shim verbatim as `--config`:

- An empty string or `{}` means no options: builder factories receive a
  `BuilderOptions` wrapping an empty map.
- A string that fails to parse as JSON, or parses to a non-object (array,
  string, number), is a hard build error — `ShimArgs.parse` rejects it
  before any Builder runs.
- The decoded map is passed unmodified as `BuilderOptions(config)` to
  **every** builder factory the target's shim runs. A macro that writes
  several targets for one builder passes its `config` to each target whose
  builder reads options: `drift_codegen` hands drift's options to its
  discover, analyzer and part stages, on the `.dart` and `.drift` sources
  alike, as build_runner hands the `drift_dev` builder's options to the
  factories it runs on both; its prep stage and the combining shim read
  none.
- Keys and values are builder-defined — the same names the builder accepts
  under `options:` in `build.yaml`. rules_dart does not read `build.yaml`
  (see [build.yaml](#buildyaml)); `config` is the
  per-target replacement. Gazelle writes it from the package's `build.yaml`
  (see [build.yaml](#buildyaml)), or from the
  `# gazelle:dart_builder_config <Annotation> <json-string>` directive (see
  [Directives](#directives)) for a package without one.

## Execution modes

### One-shot

Bazel spawns one process per action, passes `@<flagfile>` (see
`use_param_file("@%s", use_always=True)` + `multiline` format in
`dart_codegen.bzl`), process exits after writing the output.

### Persistent worker

`execution_requirements = {"supports-workers": "1",
"requires-worker-protocol": "proto", "worker-key-mnemonic":
"DartCodegen"}` triggers Bazel's worker protocol. Each shim's `main`
dispatches via `shimMain(args, factory)`:

- With `--persistent_worker`, enters `AsyncWorkerLoop`; reads repeated
  `WorkRequest`s from stdin, processes each via `runShim` in an isolate of
  its own, writes `WorkResponse` to stdout.
- Without it, runs one-shot.

The isolate gives each request the top-level state a one-shot process starts
with. Generators keep state there meant to last one build:
`json_serializable` checks the pubspec once and remembers it, so a worker
that kept it would print the check's warnings on its first request only, and
`source_gen`'s `rootPackageName` is read on first use and kept. Whatever a
builder logs at `WARNING` or above lands in `WorkResponse.output`, which
Bazel prints as it prints a one-shot action's stderr.

Singleplex only (`supports-workers`, **not**
`supports-multiplex-workers`): the shim changes the working directory for
each request and `source_gen` reads it, and the working directory belongs to
the process. Parallelism is preserved by `--worker_max_instances` spawning
multiple singleplex workers.

`WorkRequest.sandbox_dir` is honoured — when set by
`--experimental_sandboxed_worker`, staging roots there so per-request
hermeticity matches Bazel's sandbox lifecycle.

A worker runs unsandboxed in the execroot, where the package config's
`rootUri`s lead to whole package directories. The shim therefore gives the
analyzer, and the `AssetReader` builders read through, a file system
(`DeclaredResourceProvider`, through the analyzer's public `resourceProvider`)
that holds only the request's `WorkRequest.inputs`, the staging directory and
the SDK: an undeclared file of a dependency does not exist for a generator, in
a worker as in a sandbox. Nothing above the staging directory is visible
either, so the analyzer's searches upward from it (for
`analysis_options.yaml`, `pubspec.yaml`, workspace markers) end there wherever
the system temp directory is. A one-shot run sees whole packages of the
package config; the sandbox is what holds those to the declared inputs.
Generators that read files with `dart:io` rather than through the build step
are outside this view.

### Analyzer-context lifecycle

`builder_shim.dart` constructs a fresh `AnalysisContextCollection` per
request, as each request's isolate starts with none. The collection is
`dispose()`-d in `finally` so long-running workers don't leak analyzer
driver threads or file-watching handles. Dart-VM startup is still
amortised across the worker's lifetime — that's the latency win from
worker mode, not analyzer-context reuse.

### Analyzing generators

A shim is an ordinary `dart_binary`, and every executable rule hands out
`DartAnalyzableInfo`, so the `dart_analyze` aspect checks a generator like any
other target a `bazel test` names — no separate mechanism, and nothing for
`dart_codegen` to propagate.

rules_dart analyzes its own shims this way: its `.bazelrc` enables the aspect,
so `bazel test //...` checks every `dart/ext/<builder>/` binary, which is what
catches a type error in a shim at its source rather than downstream in
whatever the generated output does wrong.

The path a generator takes to the rule decides what there is to analyze.
`generator_bin` is already a target, so the same label serves both. A bare
`generator`/`generator_script` resolves to a file, and the script runs as
`dart <script>` with no package resolution of its own — `dart:` core
imports only, and no providers for an analysis rule to read. Declare a
`dart_binary` over that source as an analysis handle and leave the codegen
call alone: promoting the script to `generator_bin` to gain a target would
enlist it in the worker protocol above, which a plain `dart_binary` does
not speak. `e2e/codegen/tools/BUILD.bazel` is the worked example.

## The Resolver

`_ShimAnalyzerResolver` in `builder_shim.dart` implements the
`package:build` `Resolver` interface over `package:analyzer`. It is
the piece that must stay bug-compatible with `build_resolvers` (the
upstream Resolver implementation), since every Builder talks through it.

Key behaviours:

- **`libraryFor(AssetId)`**: for `lib/` assets, uses
  `session.getLibraryByUri(id.uri)` — _not_ `getResolvedLibrary(path)`.
  This is critical: resolving by file path produces an element model
  keyed on `file://` URIs, which mismatches the canonical `package:`
  URIs the same file gets when reached via an `import 'package:...'`
  chain. `source_gen`'s `TypeChecker.fromUrl` compares URIs string-wise;
  a mismatch silently yields zero matches.
- **`astNodeFor(Fragment)`**: uses
  `ParsedLibraryResult.getFragmentDeclaration(fragment)` to return the
  specific declaration node (class, method, field). Returning the whole
  `CompilationUnit` breaks drift's `DartTableResolver._parseColumns`
  (expects `MethodDeclaration`).
- **`assetIdForElement(Element)`**: derives `AssetId` from
  `element.library.uri`. Handles `file://` URIs by reverse-mapping
  through the PackageConfig so elements reached via transitive import
  walking still resolve.

A library outside `lib/` (`bin/`, `test/`, `web/`) has no `package:` URI,
so the analyzer names it by a `file:` URI under the shim's temporary staging
directory, and a generator that writes a library's own URI into its output
(stacked's router and locator do) would emit that temporary path. After the
builder runs, the shim parses each output with the analyzer's `parseString`
and rewrites every `import`, `export` and `part` URI under the staging
directory to the relative path a user would write (`import 'app.dart';` for a
generator run on `bin/app.dart`). The staging directory named anywhere else
in an output fails the action: there is no correct rewrite for it, and the
output would neither compile elsewhere nor be the same on two runs.

## The `BuildStep`

`_ShimBuildStep` wires reader + writer + resolver + a `ResourceManager`.
Builder log output is captured via
`runZoned(..., zoneValues: {#buildLog: logger})` — without this,
`package:build`'s `log` sinks into the default `Logger('build.fallback')`
and builder warnings/errors vanish silently. The root log level is
captured and restored per request so a Builder that elevates it
(e.g. for its own diagnostics) can't poison later worker requests.
Default level is `WARNING` (matches `build_runner_core`).

`ResourceManager` is per-request (scoped to one `runShim` call); multi-
stage pipelines each get their own and dispose all of them in `finally`
so cross-action `fetchResource` state doesn't leak.

## Rule-layer auto-staging

`deps` on `dart_codegen` / `dart_sqlcodegen` / `dart_aggregate_codegen`
accepts `dart_library`-shaped targets (anything exporting `DartInfo`).
The rule walks each dep's `DartInfo.transitive_srcs` and
`transitive_resources` and auto-stages any file whose owning package matches
the codegen target's package name — i.e. same-package sibling files. Every
file of every other package in `deps`, sources and `resources` alike, is an
input of the action, since a generator may read any of them through the
package config.

The staging root is the package root a builder sees. Builders read its
`pubspec.yaml` (`source_gen` for the package name, `json_serializable` for its
dependency on `json_annotation`), so the rule writes one from the target: its
package's name, an `environment.sdk` of `^<language_version>.0`, and every
package its `deps` reach, at the version the build uses (`any` for a workspace
package, which has none). A `pubspec.yaml` passed in `asset_deps` at the package
root is staged instead; the shim fails the action, naming both, when its `name`
or the language version pub derives from its `environment.sdk` differs from the
target's. An `analysis_options.yaml` or `stacked.json` passed there is staged
and read as is; the shim writes an empty `stacked.json` only when none is
passed. A sibling source reaches a generator through the `dart_library` that
owns it, in `deps`, not by naming its file.

A sibling no library can hold yet, because the part generated for it does
not exist (a macro's other `srcs`, or an earlier stage's output in a
cascade), is staged through `asset_deps` instead, which passes the same
`--dep`. A library has to hold every part it names, so a source-only
library of such files would fail its import check.

Implementation: `same_package_library_dep_files` + `asset_path_for` in
`dart/private/common.bzl`. The helper returns both the sibling files and
the Dart package's `package_root`, so asset paths are computed by stripping
`package_root` from `short_path` (not the codegen rule's Bazel package
path). This survives configurations where the codegen rule lives at a
deeper Bazel-package path than the Dart package root
(`//myapp/lib:codegen` for Dart package `myapp`).

## Builders from other rule sets

A rule set outside rules_dart ships a builder as rules_dart ships its own,
from `@rules_dart//dart/ext/_shared:defs.bzl`:

- `builder_shim_library(name, pub_hub)` is the shim runner,
  `package:rules_dart_ext/worker_entry.dart`, built against the packages of
  the pub hub `pub_hub` (`@<hub>`). Every library in a shim binary comes
  from one hub, so the hub that supplies the builder's package
  supplies the runner's `build` and `analyzer` too; it must resolve the
  runner's packages at versions `dart/ext/pubspec.yaml` allows. A rule set
  whose builder needs a pub SDK rules_dart's lock does not (a Flutter
  constraint) ships it this way, from a lock of its own.
- The shim is a `dart_binary` (`code_assets_from_deps = False`) whose `main`
  calls `shimMain(args, <builder factory>)`, depending on that library and
  the builder's package.
- The builder's macro calls `shared_part_codegen` (a SharedPartBuilder,
  merged into `<src>.g.dart` by rules_dart's combining shim) or
  `library_builder_codegen` (a builder writing its own files) with that
  shim, its output extension and its runtime library.

`e2e/ext_exemplar/external_builder/` is such a builder, its shim resolved
from a lock of its own.

## Gazelle synthesis

The Gazelle plugin (`gazelle/dart/`) scans `.dart` sources for
annotations matching registered builders, then emits the appropriate
codegen chain. It writes every target for a package's `lib/` in the BUILD
file at the package's root, beside the package's one `dart_library`, which
holds every source, annotated or not, and lists in `srcs` what the codegen
targets generate, as build_runner writes a `.g.dart` beside its source, a
part of the same library. The targets for a source are named for its path
under `lib/` without `.dart` (`user_codegen` for `lib/user.dart`,
`src/model/user_codegen` for `lib/src/model/user.dart`). The library holds
what a generator writes, so no generator depends on it: each sees, through
`asset_deps`, the files of the package its source reaches by imports, cycles
included, with what builders that run before its own (by `runs_before` and
`consumes`/`produces`, build_runner's earlier phases) write for them, and
depends in `deps` on the other packages those files import:

- **Single-annotation source + the builder ships a convenience macro**
  → emit one `<builder>_codegen(...)` call. (Most `dart_library` users
  see only this.)
- **Multi-annotation chain** → topologically sort by
  `consumes`/`produces` and `runs_before`, emit a chain of
  `dart_codegen` + combining. Each stage depends also on its builder's
  runtime package; a stage after a
  builder that writes part of the library (freezed's `.freezed.dart`) reads
  that output through `asset_deps`. A freezed class with a `fromJson`
  factory, or `fromJson: true` / `toJson: true` on `@Freezed`, counts as
  `@JsonSerializable` too, since freezed writes a `@JsonSerializable` class
  for json_serializable to complete.
- **A source whose builders change** → the macro or chain replaces the
  other in the library's `srcs`, and the old targets go.
- **Fan-out annotation** (e.g. `@StackedApp` drives five sub-builders)
  → emit one `dart_codegen` primitive per sub-builder, every generated
  output in the library's `srcs`.
- **Generated files in the source tree**, as a published package carries
  them: a file a codegen target Gazelle writes produces (a SharedPart
  builder's source's `.g.dart`, any other builder's `produces=`
  extensions) is in no `srcs`. Any other file is a source, whatever its
  name: a `.g.dart` no builder here writes, from a builder rules_dart does
  not know or written by hand, is in the package's library, as it is to
  `build_runner`, which treats as generated only what a builder it runs
  produces.

### Directives

The built-in builder set is not extensible via directive — if you need a
custom builder, hand-write a `dart_codegen` target. Directives below
tune _registered_ builders:

- `# gazelle:dart_builder_runtime_dep <Annotation> <label>` overrides
  the runtime Dart library the package's `dart_library` and the builder's
  codegen targets depend on
  (useful when you've forked e.g. `json_annotation`): the label replaces the
  default package there, an import of it included, and a macro states it as
  `annotation_dep`. Without it, the runtime package resolves as an import of
  it would, and a macro states it as `annotation_dep` where that is not the
  macro's default.
- `# gazelle:dart_builder_config <Annotation> <json-string>` sets the
  builder's `BuilderOptions`. Equivalent to build.yaml's `options:`
  block. Applies to every sub-builder of a fanned-out annotation. Where the
  package's `build.yaml` states other options for the same builder, Gazelle
  fails naming both.
- `# gazelle:dart_language_version <major>.<minor>` states the
  `language_version` of the package's `dart_package_metadata`, for a package
  whose `pubspec.yaml` does not.
  When unset, Gazelle derives it from the lower bound of the
  `environment.sdk` constraint in the `pubspec.yaml` at the package's root;
  a directive that disagrees with it is an error.

Every macro takes `package`, the `dart_package_metadata` of the sources'
package, and forwards it to every rule it emits; the `dart_library` collecting
the outputs names the same one. Gazelle writes that metadata at the package's
root and names it on every macro, codegen target and library it writes.

### build.yaml

For a package it writes codegen for, Gazelle reads `build.yaml` at the
package's root and carries the one part of it a Bazel build has a place for:
`targets.$default.builders.<builder>.options` of a builder it writes targets
for becomes their `config`, the JSON object build_runner would hand the
builder. A builder is named as build_runner names it, `<package>:<builder>`,
a bare `<package>` meaning the builder of that name and `|` the older
separator:

| Annotation | build.yaml builder |
|---|---|
| `@JsonSerializable` | `json_serializable` |
| `@freezed` / `@Freezed` | `freezed` |
| `@BuiltValue`, `Built<…>`, `@SerializersFor` | `built_value_generator:built_value` |
| `@CopyWith` | `copy_with_extension_gen` |
| `@GenerateMocks` | `mockito:mockBuilder` |
| `@DriftDatabase` | `drift_dev` |
| `@StackedApp` | `stacked_generator:stackedRouterGenerator`, `…LocatorGenerator`, `…LoggerGenerator`, `…DialogGenerator`, `…BottomsheetGenerator` |
| `@FormView` | `stacked_generator:stackedFormGenerator` |

Every other part of the file fails generation, named by its path, before any
BUILD file is written: a target other than `$default`, a target's `sources`,
a builder's `generate_for`, `enabled`, `dev_options` or `release_options`,
`global_options`, a builder outside the table (source_gen's
`combining_builder` too, whose shim takes no options), and a `build.<name>.yaml`. A codegen macro's `srcs`
choose the files it runs on. `# gazelle:exclude build.yaml` in the package
root's BUILD file has Gazelle not read the file, for a package that keeps it
for build_runner alone.

## Generated files in the source tree

A package that publishes carries its generated files (`.g.dart`,
`.freezed.dart`, …) in its source tree, as `build_runner`'s README requires,
so a checkout can hold a `lib/user.g.dart` next to a `dart_codegen` target
that produces `lib/user.g.dart`. rules_dart never runs `build_runner`; three
independent mechanisms keep the checked-in file from breaking the Bazel
build. Each has a dedicated test.

- **Gazelle leaves generated files out of the BUILD files it writes.**
  A file a codegen target Gazelle writes produces is in no `srcs`; a file
  no target produces is a source, whatever its name (see
  [Gazelle synthesis](#gazelle-synthesis)). Pinned by the
  `dev/testdata/dart_generated_in_source_tree` fixture (first-time
  generation) and `dev/testdata/dart_generated_in_source_tree_update`
  (rewrite of an existing BUILD whose `srcs` still lists the files).
- **`dart_library` fails the build if a hand-written `srcs` lists a
  collision.** If two files in `srcs` resolve to the same
  package-relative path — e.g. a checked-in `lib/user.g.dart` next to a
  `dart_codegen` target producing `lib/user.g.dart` — `dart_library`
  fails with a diagnostic pointing at both paths. Pinned by unit tests
  in `dart/tests:library_test`.
- **Runfiles layout favours the declared output.** Even when a checked-in
  `lib/user.g.dart` lives next to its source, the `dart_test`'s
  runfiles tree gets the `bazel-out/` version, not the source-tree
  copy. Pinned by `e2e/ext_exemplar/source_tree_generated/`: its checked-in
  `lib/user.g.dart` returns intentionally-wrong values (`STALE_NAME`,
  `-999`), so the JSON round-trip assertions in `user_test.dart` would
  fail if that file ever leaked into runfiles.

## Equivalence with `build_runner`

For any `build.yaml` over a set of `package:build` Builders, an
equivalent rules_dart target configuration produces bit-identical Builder
output and preserves ordering constraints. The argument:

1. **Identical Builder execution.** We call `Builder.build(BuildStep)`
   using `package:build` and `package:analyzer` at the versions
   `dart/ext/pubspec.lock` pins. Given the same
   inputs, config, and Resolver state, `build()` is deterministic. Our
   Resolver is bug-compatible with `build_resolvers` for the behaviour
   bundled builders depend on (URI canonicalisation,
   `getFragmentDeclaration`, metadata constant evaluation).
2. **Directive-set completeness.** Every declarative field in a
   `build.yaml` entry has a corresponding backing in the rules_dart
   builder registry (`annotation`, `produces`, `consumes`, `runs_before`,
   `shared_part`, `aggregate`).
3. **DAG semantics match.** `build_runner` topologically orders builders
   from declarative fields; Bazel topologically orders targets from its
   action graph. Equivalent input DAGs → equivalent execution orders.

Out of scope (off-spec in `build_runner` too, or intentionally not modelled):

- `BuildStep.fetchResource` cross-action state — per-request
  `ResourceManager`.
- `PostProcessBuilder` — Bazel sandbox teardown replaces it.
- Watch-mode incrementality — Bazel actions cold-start per change.
- Builders reading files outside declared inputs — relies on CWD
  semantics that are off-spec.

## End-to-end examples

Each supported builder has a dedicated e2e exemplar under
`e2e/ext_exemplar/` covering its full feature surface. Read the
`BUILD.bazel` + `lib/` + `test/` triple to see a working realistic
configuration.

| Builder                                          | Exemplar                              | What it covers                                                                                                                                                         |
| ------------------------------------------------ | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `json_serializable` / `json_annotation`          | `e2e/ext_exemplar/json_serializable/` | Basic + primitives form, `FieldRename.snake`, `@JsonKey(name:/toJson:/fromJson:)`, `@JsonEnum`, `@JsonConverter`, `genericArgumentFactories`, cross-file Resolver      |
| `freezed` / `freezed_annotation`                 | `e2e/ext_exemplar/freezed/`           | Value class, sealed unions (`when`/`map`/`maybeWhen`), `copyWith`, `@Default`, equality                                                                                |
| `built_value` / `built_value_generator`          | `e2e/ext_exemplar/built_value/`       | `Built<T,TBuilder>` + `rebuild`, `Serializer<T>`, `@SerializersFor`, `BuiltList`, nullable fields, `StandardJsonPlugin`                                                |
| `mockito`                                        | `e2e/ext_exemplar/mockito/`           | `@GenerateMocks` (cross-file), `@GenerateNiceMocks`, `MockSpec(as:)`, `OnMissingStub.returnDefault`                                                                    |
| `copy_with_extension_gen`                        | `e2e/ext_exemplar/copy_with/`         | `@CopyWith()`, per-field shortcuts, `copyWithNull`, `@CopyWithField(immutable:)`                                                                                       |
| `drift` / `drift_dev`                            | `e2e/ext_exemplar/drift/`             | `@DriftDatabase(include: {'…drift'})`, Dart-only tables with FK, `@DriftAccessor` DAO, `TypeConverter`, multi-table joins via both Dart DSL and `.drift` named queries |
| `stacked` / `stacked_generator` (6 sub-builders) | `e2e/ext_exemplar/stacked/`           | `@StackedApp` → locator (behavioral) + router/dialog/bottomsheet/logger (structural); `@FormView` → form (structural)                                                  |

Cross-cutting scenarios that aren't tied to a single builder:

| Exemplar                                  | What it demonstrates                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `e2e/ext_exemplar/cascade_two_stage/`     | Multi-annotation chain on one file (freezed → json cascade); DAG topological ordering + combining integration |
| `e2e/ext_exemplar/multi_shard_combining/` | Multiple SharedPart builders on one source (json + copy_with) merged into one `.g.dart`                       |
| `e2e/ext_exemplar/source_tree_generated/` | A `.g.dart` checked into the source tree doesn't leak into Bazel runfiles                                    |
| `e2e/ext_exemplar/unique_extension/`      | Custom `output_suffixes` on `dart_codegen` — the rules-layer customisation path                               |
| `e2e/ext_exemplar/external_builder/`      | A builder from outside rules_dart: its shim built against its own pub resolution, its macro over `shared_part_codegen` |
