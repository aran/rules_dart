# rules_dart — Code Generation (`dart/ext/`)

## Goal

Run the `package:build` `Builder` ecosystem (`json_serializable`,
`freezed`, `built_value`, `mockito`, `go_router`, `copy_with_extension_gen`,
`stacked`, `drift`) under Bazel without `build_runner`.
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
├── go_router/
├── copy_with_extension_gen/
├── stacked/                   Six independent LibraryBuilders.
├── drift/                     Four-stage: prep + discover/analyzer/driftBuilder.
└── tools/
    └── check_dual_build_collisions
                               Walks a source tree for committed `build_runner`
                               outputs that would collide with Bazel codegen
                               outputs. Uses the same extension catalog as
                               Gazelle's filter.
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
  builder reads options: `drift_library` hands drift's options to its
  discover, analyzer and part stages, on the `.dart` and `.drift` sources
  alike, as build_runner hands the `drift_dev` builder's options to the
  factories it runs on both; its prep stage and the combining shim read
  none.
- Keys and values are builder-defined — the same names the builder accepts
  under `options:` in `build.yaml`. rules_dart does not read `build.yaml`
  (see [Dual-build coexistence](#dual-build-coexistence)); `config` is the
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
the codegen target's `package_name` — i.e. same-package sibling files. Every
file of every other package in `deps`, sources and `resources` alike, is an
input of the action, since a generator may read any of them through the
package config.

The staging root is the package root a builder sees. Builders read its
`pubspec.yaml` (`source_gen` for the package name, `json_serializable` for its
dependency on `json_annotation`), so the rule writes one from the target: its
`package_name`, an `environment.sdk` of `^<language_version>.0`, and every
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

## Gazelle synthesis

The Gazelle plugin (`gazelle/dart/`) scans `.dart` sources for
annotations matching registered builders, then emits the appropriate
codegen chain:

- **Single-annotation source + the builder ships a convenience macro**
  → emit one `<builder>_library(...)` call. (Most `dart_library` users
  see only this.)
- **Multi-annotation chain** → topologically sort by
  `consumes`/`produces` and `runs_before`, emit a chain of
  `dart_codegen` + combining + `dart_library`. Each stage depends on what
  the source imports and on its builder's runtime package; a stage after a
  builder that writes part of the library (freezed's `.freezed.dart`) reads
  that output through `asset_deps`. A freezed class with a `fromJson`
  factory, or `fromJson: true` / `toJson: true` on `@Freezed`, counts as
  `@JsonSerializable` too, since freezed writes a `@JsonSerializable` class
  for json_serializable to complete.
- **A source whose builders change** → the macro or chain library of the
  same name replaces the other, and the chain's stages go.
- **Fan-out annotation** (e.g. `@StackedApp` drives five sub-builders)
  → emit one `dart_codegen` primitive per sub-builder, plus a wrapping
  `dart_library` with every generated output in `srcs`.
- **Generated files** (`.g.dart`, `.freezed.dart`, `.mocks.dart`,
  `.config.dart`, `.module.dart`, any registered `produces=` extension)
  are excluded from `dart_library` srcs — see `filterOutGeneratedFiles`
  in `generate.go`.

### Directives

The built-in builder set is not extensible via directive — if you need a
custom builder, hand-write a `dart_codegen` target. Directives below
tune _registered_ builders:

- `# gazelle:dart_builder_runtime_dep <Annotation> <label>` overrides
  the runtime Dart library the emitted `dart_library` depends on
  (useful when you've forked e.g. `json_annotation`). Without it, the
  runtime package resolves as an import of it would, and a macro states it
  as `annotation_dep` where that is not the macro's default.
- `# gazelle:dart_builder_config <Annotation> <json-string>` sets the
  builder's `BuilderOptions`. Equivalent to build.yaml's `options:`
  block. Applies to every sub-builder of a fanned-out annotation. Where the
  package's `build.yaml` states other options for the same builder, Gazelle
  fails naming both.
- `# gazelle:dart_language_version <major>.<minor>` states the
  `language_version` attr for a package whose `pubspec.yaml` does not.
  When unset, Gazelle derives it from the lower bound of the
  `environment.sdk` constraint in the `pubspec.yaml` at the package's root;
  a directive that disagrees with it is an error.

Every macro also accepts `package`, a `dart_package_metadata` label
declaring the package's `package_name` and `language_version` once. It is
forwarded to every rule the macro emits, and is mutually exclusive with
passing those two inline.

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
| `@TypedGoRoute` | `go_router_builder` |
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

## Dual-build coexistence

rules_dart does not run `build_runner` and supports no system-wide install of
it (see the [README](../README.md#command-map)). A checkout migrating from
`build_runner` may still hold files it wrote, and a pipeline that has not yet
dropped it; the guarantees below keep the first from breaking the Bazel build
and Bazel's files from breaking the second:

### 1. `build_runner`-generated files in the source tree don't break Bazel

Three independent mechanisms guard this. Each has a dedicated test.

- **Gazelle drops stale files from generated BUILD files.**
  `filterOutGeneratedFiles` in `gazelle/dart/generate.go` excludes every
  registered `produces=` extension (`.g.dart`, `.freezed.dart`,
  `.mocks.dart`, …) from `dart_library.srcs`. Pinned by the
  `dev/testdata/dual_build_coexistence` fixture (first-time generation)
  and `dev/testdata/dual_build_coexistence_update` (rewrite of an
  existing BUILD whose `srcs` still lists the stale files).
- **`dart_library` fails the build if a hand-written `srcs` lists a
  collision.** If two files in `srcs` resolve to the same
  package-relative path — e.g. a committed `lib/user.g.dart` next to a
  `dart_codegen` target producing `lib/user.g.dart` — `dart_library`
  fails with a diagnostic pointing at both paths. Pinned by unit tests
  in `dart/tests:library_test`.
- **Runfiles layout favours the declared output.** Even when a stale
  `lib/user.g.dart` lives next to its source, the `dart_test`'s
  runfiles tree gets the `bazel-out/` version, not the source-tree
  copy. Pinned by `e2e/ext_exemplar/dual_build_sample/`: its committed
  `lib/user.g.dart` returns intentionally-wrong values (`STALE_NAME`,
  `-999`), so the JSON round-trip assertions in `user_test.dart` would
  fail if that file ever leaked into runfiles.

### 2. Bazel scaffolding doesn't break `build_runner`

`package:build`'s asset discovery walks only `lib/`, `test/`, `bin/`,
`web/`, `tool/` — never the repo root, where `BUILD.bazel`,
`MODULE.bazel`, and `bazel-*` convenience symlinks live. Pinned by
`e2e/dual_build/run_build_runner_test`, which runs a real `pub get` and
`build_runner` with the pinned SDK and so needs the network.

### Recommendations

- **`.gitignore`** generated file extensions so `build_runner`'s leftover
  output doesn't enter VCS:

  ```
  .dart_tool/
  **/*.g.dart
  **/*.freezed.dart
  **/*.mocks.dart
  **/*.config.dart
  **/*.module.dart
  **/*.drift.dart
  **/*.gr.dart
  **/*.locator.dart
  **/*.router.dart
  **/*.form.dart
  **/*.logger.dart
  **/*.dialogs.dart
  **/*.bottomsheets.dart
  ```

- **`bazel run @rules_dart//dart/ext/tools:check_dual_build_collisions
-- path/to/repo`** flags every source-tree file matching a generator's
  produced extension. Non-zero exit on findings; useful as a pre-commit
  hook. Reads the extensions `baseline_generated_extensions.txt` lists,
  which Gazelle's `filterOutGeneratedFiles` also filters from a copy in the
  plugin's module; a test keeps the two copies the same.

- **`build.yaml`** is not read by rules_dart. Builder options set there
  apply only under `build_runner`. Pass equivalent options via the
  macro's `config = "{...}"` argument (per-target), the
  `# gazelle:dart_builder_config` directive (per-directory), or let Gazelle
  write them from `build.yaml` (see [build.yaml](#buildyaml)).

### Out of scope

- Permanent coexistence as a production mode.
- Byte-identical output between the two tools.
- `build_runner` daemon interop.
- `PostProcessBuilder` and other `build_runner`-specific hooks.

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
| `go_router_builder`                              | `e2e/ext_exemplar/go_router/`         | `@TypedGoRoute` + nested routes + path params (structural test via local pure-Dart `go_router` stub)                                                                   |
| `copy_with_extension_gen`                        | `e2e/ext_exemplar/copy_with/`         | `@CopyWith()`, per-field shortcuts, `copyWithNull`, `@CopyWithField(immutable:)`                                                                                       |
| `drift` / `drift_dev`                            | `e2e/ext_exemplar/drift/`             | `@DriftDatabase(include: {'…drift'})`, Dart-only tables with FK, `@DriftAccessor` DAO, `TypeConverter`, multi-table joins via both Dart DSL and `.drift` named queries |
| `stacked` / `stacked_generator` (6 sub-builders) | `e2e/ext_exemplar/stacked/`           | `@StackedApp` → locator (behavioral) + router/dialog/bottomsheet/logger (structural); `@FormView` → form (structural)                                                  |

Cross-cutting scenarios that aren't tied to a single builder:

| Exemplar                                  | What it demonstrates                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `e2e/ext_exemplar/cascade_two_stage/`     | Multi-annotation chain on one file (freezed → json cascade); DAG topological ordering + combining integration |
| `e2e/ext_exemplar/multi_shard_combining/` | Multiple SharedPart builders on one source (json + copy_with) merged into one `.g.dart`                       |
| `e2e/ext_exemplar/dual_build_sample/`     | Source-tree `.g.dart` files committed by `build_runner` don't leak into Bazel runfiles                        |
| `e2e/ext_exemplar/unique_extension/`      | Custom `output_suffixes` on `dart_codegen` — the rules-layer customisation path                               |
