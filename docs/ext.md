# rules_dart — Code Generation (`dart/ext/`)

## Goal

Run the `package:build` `Builder` ecosystem (`json_serializable`,
`freezed`, `built_value`, `mockito`, `go_router`, `copy_with_extension_gen`,
`injectable`, `stacked`, `drift`) under Bazel without `build_runner`.
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
│   │                          AssetWriter, Resolver (analyzer 10.x),
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
├── injectable/                Two-stage: shim_metadata + shim_config.
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
                                         output builders like injectable's
                                         config stage, which emits both
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
  **every** stage's builder factory in the target's pipeline; multi-stage
  shims (drift's sub-builders, injectable's metadata + config stages) all
  see the same options.
- Keys and values are builder-defined — the same names the builder accepts
  under `options:` in `build.yaml`. rules_dart does not read `build.yaml`
  (see [Dual-build coexistence](#dual-build-coexistence)); `config` is the
  per-target replacement, and the
  `# gazelle:dart_builder_config <Annotation> <json-string>` directive (see
  [Directives](#directives)) is the per-directory one.

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
  `WorkRequest`s from stdin, processes each via `runShim`, writes
  `WorkResponse` to stdout.
- Without it, runs one-shot.

Singleplex only (`supports-workers`, **not**
`supports-multiplex-workers`). `source_gen`'s `rootPackageName` is a
CWD-reading top-level `final`; multiplexing would need to patch upstream
`source_gen`, which project policy forbids. Parallelism is preserved by
`--worker_max_instances` spawning multiple singleplex workers.

`WorkRequest.sandbox_dir` is honoured — when set by
`--experimental_sandboxed_worker`, staging roots there so per-request
hermeticity matches Bazel's sandbox lifecycle.

### Analyzer-context lifecycle

`builder_shim.dart` constructs a fresh `AnalysisContextCollection` per
request. Reusing one across requests is a silent-corruption hazard:
`source_gen`'s `rootPackageName` is process-pinned on first read, so a
second request with a different package name would be misattributed
through `source_gen`'s `_fileToAssetUrl` path. The collection is
`dispose()`-d in `finally` so long-running workers don't leak analyzer
driver threads or file-watching handles. Dart-VM startup is still
amortised across the worker's lifetime — that's the latency win from
worker mode, not analyzer-context reuse.

### Analyzing generators

A shim is an ordinary `dart_binary`, and every executable rule hands out
`DartAnalyzableInfo`, so a generator is an ordinary `dart_analyze_test`
operand — no separate mechanism, and nothing for `dart_codegen` to
propagate:

```starlark
dart_analyze_test(name = "analyze_shim", size = "small", target = ":shim")
```

rules_dart analyzes its own shims this way; every `dart/ext/<builder>/`
package carries one such target beside its binary, and they are what would
catch a type error in a shim at its source rather than downstream in
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
`package:build` `Resolver` interface over `package:analyzer` 10.x. It is
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
The rule walks each dep's `DartInfo.transitive_srcs` and auto-stages any
file whose owning package matches the codegen target's `package_name` —
i.e. same-package sibling files. Users no longer hand-list
`deps = ["lib/api.dart"]`; they add the owning `dart_library` target to
`deps` instead.

Implementation: `same_package_library_dep_files` + `asset_path_for` in
`dart/private/common.bzl`. The helper returns both the sibling files and
the Dart package's `lib_root`, so asset paths are computed by stripping
`lib_root` from `short_path` (not the codegen rule's Bazel package
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
  `dart_codegen` + combining + `dart_library`.
- **Fan-out annotation** (e.g. `@StackedApp` drives five sub-builders)
  → emit one `dart_codegen` primitive per sub-builder, plus a wrapping
  `dart_library` with every generated output in `srcs`.
- **Directory-level aggregate** (`@InjectableInit`) → emit a single
  `injectable_library(...)` macro for the whole directory; `srcs`
  covers every file so the metadata stage sees them all, `init_src`
  points at the `@InjectableInit` file.
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
  (useful when you've forked e.g. `json_annotation`).
- `# gazelle:dart_builder_config <Annotation> <json-string>` sets the
  builder's `BuilderOptions`. Equivalent to build.yaml's `options:`
  block. Applies to every sub-builder of a fanned-out annotation.
- `# gazelle:dart_language_version <major>.<minor>` overrides the
  `language_version` attr. When unset, Gazelle derives it from the
  nearest `pubspec.yaml`'s `environment.sdk` constraint's lower bound.

## Dual-build coexistence

`rules_dart` and `build_runner` can be used on the same checkout during
a migration:

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
`e2e/dual_build/run_build_runner_test` (tagged `manual` because it runs
real `dart pub get`; enable in CI with `--test_tag_filters=+manual`).

### Recommendations

- **`.gitignore`** generated file extensions so `build_runner` output
  doesn't enter VCS:

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
  hook. Reads the same `baseline_generated_extensions.txt` that
  Gazelle's `filterOutGeneratedFiles` consumes, so the two stay in sync.

- **`build.yaml`** is not read by rules_dart. Builder options set there
  apply only under `build_runner`. Pass equivalent options via the
  macro's `config = "{...}"` argument (per-target) or the
  `# gazelle:dart_builder_config` directive (per-directory).

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
   using `package:build` 4.x + `package:analyzer` 10.x. Given the same
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
| `injectable` / `injectable_generator`            | `e2e/ext_exemplar/injectable/`        | Macro + primitive pipelines, `@injectable`, `@singleton`, `@lazySingleton`, `@module`, `@Named`, `@Environment`                                                        |
| `drift` / `drift_dev`                            | `e2e/ext_exemplar/drift/`             | `@DriftDatabase(include: {'…drift'})`, Dart-only tables with FK, `@DriftAccessor` DAO, `TypeConverter`, multi-table joins via both Dart DSL and `.drift` named queries |
| `stacked` / `stacked_generator` (6 sub-builders) | `e2e/ext_exemplar/stacked/`           | `@StackedApp` → locator (behavioral) + router/dialog/bottomsheet/logger (structural); `@FormView` → form (structural)                                                  |

Cross-cutting scenarios that aren't tied to a single builder:

| Exemplar                                  | What it demonstrates                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `e2e/ext_exemplar/cascade_two_stage/`     | Multi-annotation chain on one file (freezed → json cascade); DAG topological ordering + combining integration |
| `e2e/ext_exemplar/multi_shard_combining/` | Multiple SharedPart builders on one source (json + copy_with) merged into one `.g.dart`                       |
| `e2e/ext_exemplar/dual_build_sample/`     | Source-tree `.g.dart` files committed by `build_runner` don't leak into Bazel runfiles                        |
| `e2e/ext_exemplar/unique_extension/`      | Custom `output_suffixes` on `dart_codegen` — the rules-layer customisation path                               |
