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
│   ├── worker_entry.dart      AsyncWorkerLoop subclass; runs each request in
│   │                          a fresh isolate. `shimMain` dispatches worker
│   │                          vs one-shot.
│   └── src/declared_file_system.dart
│                              The file system holding only declared inputs.
├── defs.bzl                   The builder API: `builder_shim_library`,
│                              `shared_part_codegen`, `library_builder_codegen`.
├── registry.bzl               Curated code assets and dependency cycles for
│                              pub packages.
├── combining_shim/bin/        Concatenates SharedPart shards into one .g.dart,
│                              mirroring source_gen|combining_builder.
├── json_serializable/         One shim binary + convenience macro per builder.
├── freezed/
├── built_value/
├── mockito/
├── copy_with_extension_gen/
├── stacked/                   Six independent LibraryBuilders.
├── drift/                     Four-stage: prep + discover/analyzer/driftBuilder.
├── sqlite3/, webcrypto/       Code assets replacing those packages' build hooks.
└── test/                      The shim runner's tests.
```

Every shim binary is a `dart_binary(compile_mode="exe")`. In worker mode
it reads `WorkRequest` protos from stdin and writes `WorkResponse` protos
to stdout; in one-shot mode it accepts a `@<flagfile>` argument and exits.

## Shim contract

All shim CLIs share this contract (`dart/ext/lib/builder_shim.dart:ShimArgs.parse`):

```
--input <exec-path>                      Primary input file.
--input-asset <asset-path>               Asset path of --input relative to its
                                         package root (lib/src/...).
--output <path>                          Declared output file. Repeatable — one
                                         per declared Bazel output (for multi-
                                         output builders, e.g. drift's
                                         analyzer emitting both
                                         `.dart.drift_module.json` and
                                         `.dart.types.temp.dart`).
--package <name>                         Owning Dart package name (required).
--root-language-version <major.minor>    Consumer's language version (required).
--dep <exec-path>|<asset-path>           Additional source visible to analyzer.
                                         Repeatable.
--input-asset-extra <exec-path>|<asset>  Aggregate mode: additional inputs
                                         (dart_aggregate_codegen only).
--part <path>                            SharedPart shard. Repeatable
                                         (combining_shim only).
--config <json-string>                   Builder options.
--package-config <path>                  Synthesised package_config.json of
                                         every package `deps` reach.
--sdk-summary <path>                     Summary of the Dart SDK the analyzer
                                         reads, which this shim wrote.
--sdk-path <dir>                         Dart SDK root, read from source:
                                         only when a `sky_engine` is among
                                         the packages. Exclusive with
                                         --sdk-summary.
[--persistent_worker]                    Switches to bazel_worker protocol.
```

`sdk-summary --sdk <dir> --out <file>` instead writes the summary of the SDK
at `<dir>` that `--sdk-summary` reads (`shimMain` runs it one-shot).

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
  under `options:` in `build.yaml`. The rules do not read `build.yaml`
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
"requires-worker-protocol": "proto", "worker-key-mnemonic": ...}` triggers
Bazel's worker protocol, keyed `DartCodegen`, `DartAggregateCodegen` or
`DartSqlCodegen` by rule. Each shim's `main`
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

`WorkRequest.sandbox_dir`, when set, roots the staging directory there.
Bazel sets it only for multiplex workers under multiplex sandboxing, so for
the singleplex shims it is unset and staging goes to the system temp
directory.

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
driver threads or file-watching handles. Dart-VM startup is
amortised across the worker's lifetime — that's the latency win from
worker mode, not analyzer-context reuse.

### The SDK, from a summary

The analyzer reads the Dart SDK from a summary rather than from its
sources, as `build_resolvers` does for build_runner: one input in place of
some 470 files, and no SDK library parsed and linked again by each action.
The analyzer's summaries carry no format version, and one written by another
version of the analyzer is misread rather than refused, so a generator reads
only a summary it wrote itself. An aspect on the codegen rules' `generator`
runs each generator once per SDK as `<generator> sdk-summary`, and every action
running that generator reads the summary it wrote: a generator built against
another `analyzer` (one from another rule set's pub hub) is another binary,
with a summary of its own.

The aspect recognises a generator by the shim runner (`rules_dart_ext`)
among the packages it links. One that does not link it, such as the
combining shim, runs no analyzer and is given no SDK at all. A `sky_engine`
adds libraries to the SDK through its `_embedder.yaml` (Flutter's `dart:ui`),
which the analyzer reads only from the SDK's sources: an action whose packages
include one is given the SDK's sources and `--sdk-path` instead. Flutter
supplies `sky_engine` for analysis alone (a `flutter_library` names it in
`dart_info()`'s `analysis_deps`, and nothing compiles it), so an action
stages what its `deps` are analyzed with, `DartInfo.analysis_only` beside
their compile closure, as the `dart_analyze` aspect does for a target analyzed
from source: a library above a `flutter_library` resolves `dart:ui` in either.

### Analyzing generators

A shim is an ordinary `dart_binary`, and every executable rule hands out
`DartAnalyzableInfo`, so the `dart_analyze` aspect checks a generator like any
other target a `bazel test` names — no separate mechanism, and nothing for
`dart_codegen` to propagate.

rules_dart analyzes its own shims this way: its `.bazelrc` enables the aspect,
so `bazel test //...` checks every `dart/ext/<builder>/` binary, which is what
catches a type error in a shim at its source rather than downstream in
whatever the generated output does wrong.

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
The shim sets the level to `WARNING` for the run, so a builder's
`INFO` messages do not reach the action's output.

`ResourceManager` is per request: one per `runShim` call, shared by every
stage of a multi-stage pipeline, as build_runner shares one across a build,
and disposed once in `finally`, so `fetchResource` state doesn't leak into
the next request.

## Rule-layer auto-staging

`deps` on `dart_codegen` / `dart_sqlcodegen` / `dart_aggregate_codegen`
accepts `dart_library`-shaped targets (anything exporting `DartInfo`), and
the `dart_package_member`s of a cycle the source's package is in, whose own
files it reads in place of the cycle's library (`codegen_deps.bzl`).
The rule walks each dep's `DartInfo.transitive_srcs` and
`transitive_resources`, and each member's files, and auto-stages every file
under the `lib/` of the codegen target's package — i.e. same-package sibling
files. Every
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
`dart/private/common.bzl`. Asset paths are computed by stripping the Dart
package's `package_root` from `short_path` (not the codegen rule's Bazel
package path): the root of the `dart_package_metadata` the target names, or,
naming none, the root `deps` give its package. This survives configurations where the codegen rule lives at a
deeper Bazel-package path than the Dart package root
(`//myapp/lib:codegen` for Dart package `myapp`).

## Builders from other rule sets

A rule set outside rules_dart ships a builder as rules_dart ships its own,
from `@rules_dart//dart/ext:defs.bzl`:

- `builder_shim_library(name, pub_hub)` is the shim runner,
  `package:rules_dart_ext/worker_entry.dart`, built against the packages of
  the pub hub `pub_hub` (`@<hub>`). Every library in a shim binary comes
  from one hub, so the hub that supplies the builder's package
  supplies the runner's `build` and `analyzer` too; it must resolve the
  runner's packages at versions `dart/ext/pubspec.yaml` allows. A rule set
  whose builder needs a pub SDK rules_dart's lock does not (a Flutter
  constraint) ships it this way, from a lock of its own.
- The shim is a `dart_binary` (`code_assets_from_packages = False`) whose `main`
  calls `shimMain(args, <builder factory>)`, depending on that library and
  the builder's package.
- The builder's macro calls `shared_part_codegen` (a SharedPartBuilder,
  merged into `<src>.g.dart` by rules_dart's combining shim) or
  `library_builder_codegen` (a builder writing its own files) with that
  shim, its output extension and its runtime library.

`e2e/examples/builders/external_builder/` is such a builder, its shim resolved
from a lock of its own.

## Gazelle synthesis

The Gazelle plugin (`gazelle/dart/`) scans `.dart` sources for
annotations matching registered builders, then emits the appropriate
codegen chain. It writes every target for a package's `lib/` in the BUILD
file at the package's root, beside the package's one `dart_library`, which
holds every source, annotated or not, and lists in `srcs` what the codegen
targets generate, as build_runner writes a `.g.dart` beside its source, a
part of the same library. A source's convenience macro is named for its
path under `lib/` without `.dart` (`user_codegen` for `lib/user.dart`,
`src/model/user_codegen` for `lib/src/model/user.dart`); the stages of a
chain are private targets from the same stem (`_user_<annotation>_gen`, with
the output's leading segment added for a fan-out builder, and
`_user_combined` for the combining step). The library holds
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

A builder another module ships (see
[Builders from other rule sets](#builders-from-other-rule-sets)) is
registered by a directive in the BUILD file at the repository's root, for
the whole repository:

```
# gazelle:dart_builder <Annotation> macro=<file>%<symbol> shim=<label> produces=<ext>[,<ext>] runtime_dep=<label> [key=<package>:<builder>]
```

`macro` is the builder's codegen macro, which Gazelle writes for a source
carrying only that annotation, loading it from `<file>`; `shim` is its shim
binary, which Gazelle runs in a `dart_codegen` stage for a source carrying
other builders' annotations too; `produces` is the extensions it writes, a
single `.<name>.g.part` making it a SharedPartBuilder whose part the
combining shim merges into `<src>.g.dart`; `runtime_dep` is the library of
its annotation, the macro's default `annotation_dep`; `key` is its
build.yaml key, whose options become its `config`. The macro is a rule kind
Gazelle must know before it reads any directory, so the directive is read
from the root alone, as Gazelle reads `# gazelle:repository_macro` from the
WORKSPACE file; in any other BUILD file it is an error, as is an annotation
or macro name already registered.

The directives below tune registered builders:

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
for becomes their `config` (options of a builder in the table that the
package's sources do not use are read and carried nowhere), the JSON object build_runner would hand the
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

Every other part of the file fails generation, each named by its key path
and line, before any BUILD file is written: a target other than `$default`, a
target's `sources`, a builder's `generate_for`, `enabled`, `dev_options` or
`release_options`, `global_options`, the options of a builder none of the
package's sources needs, a builder outside the table and the
`key`s of `dart_builder` directives (source_gen's `combining_builder` too,
whose shim takes no options). A codegen macro's `srcs` choose the files it
runs on. `# gazelle:dart_build_yaml_ignore <key path>` in the BUILD file beside
the `build.yaml` acknowledges one such part, which the build goes without, so
that Gazelle carries the rest; the error names the directive for each part.
An ignore that names no such part of that file is an error, as is one stated
twice. A `build.<name>.yaml` fails generation whole.
`# gazelle:exclude build.yaml` (or `build.<name>.yaml`) in the package root's
BUILD file has Gazelle not read the file, for a package that keeps it for
build_runner alone.

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
  copy. Pinned by `e2e/examples/builders/source_tree_generated/`: its checked-in
  `lib/user.g.dart` returns intentionally-wrong values (`STALE_NAME`,
  `-999`), so the JSON round-trip assertions in `user_test.dart` would
  fail if that file ever leaked into runfiles.

## Equivalence with `build_runner`

For a `build.yaml` within what [build.yaml](#buildyaml) accepts, over a
set of `package:build` Builders, an equivalent rules_dart target
configuration produces bit-identical Builder output and preserves ordering
constraints. The argument:

1. **Identical Builder execution.** We call `Builder.build(BuildStep)`
   using `package:build` and `package:analyzer` at the versions
   `dart/ext/pubspec.lock` pins. Given the same
   inputs, config, and Resolver state, `build()` is deterministic. Our
   Resolver is bug-compatible with `build_resolvers` for the behaviour
   bundled builders depend on (URI canonicalisation,
   `getFragmentDeclaration`, metadata constant evaluation).
2. **Directive-set completeness.** What build.yaml states that this
   accepts, a builder's outputs, ordering and options, has a backing in the
   Gazelle builder registry (`produces`, `consumes`, `runs_before`,
   `shared_part`, and `key` for the options it carries as `config`), which
   adds the annotation that selects the builder for a source.
3. **DAG semantics match.** `build_runner` topologically orders builders
   from declarative fields; Bazel topologically orders targets from its
   action graph. Equivalent input DAGs → equivalent execution orders.

Out of scope (off-spec in `build_runner` too, or intentionally not modelled):

- `BuildStep.fetchResource` cross-action state — one `ResourceManager`
  per request.
- `PostProcessBuilder` — Bazel sandbox teardown replaces it.
- Watch-mode incrementality — Bazel actions cold-start per change.
- Builders reading files outside declared inputs — relies on CWD
  semantics that are off-spec.

## End-to-end examples

Each supported builder has a dedicated e2e exemplar under
`e2e/examples/builders/` covering its full feature surface. Read the
`BUILD.bazel` + `lib/` + `test/` triple to see a working realistic
configuration.

| Builder                                          | Exemplar                              | What it covers                                                                                                                                                         |
| ------------------------------------------------ | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `json_serializable` / `json_annotation`          | `e2e/examples/builders/json_serializable/` | Basic + primitives form, `FieldRename.snake`, `@JsonKey(name:/toJson:/fromJson:)`, `@JsonEnum`, `@JsonConverter`, `genericArgumentFactories`, cross-file Resolver      |
| `freezed` / `freezed_annotation`                 | `e2e/examples/builders/freezed/`           | Value class, sealed unions (`when`/`map`/`maybeWhen`), `copyWith`, `@Default`, equality                                                                                |
| `built_value` / `built_value_generator`          | `e2e/examples/builders/built_value/`       | `Built<T,TBuilder>` + `rebuild`, `Serializer<T>`, `@SerializersFor`, `BuiltList`, nullable fields, `StandardJsonPlugin`                                                |
| `mockito`                                        | `e2e/examples/builders/mockito/`           | `@GenerateMocks` (cross-file), `@GenerateNiceMocks`, `MockSpec(as:)`, `OnMissingStub.returnDefault`                                                                    |
| `copy_with_extension_gen`                        | `e2e/examples/builders/copy_with/`         | `@CopyWith()`, per-field shortcuts, `copyWithNull`, `@CopyWithField(immutable:)`                                                                                       |
| `drift` / `drift_dev`                            | `e2e/examples/builders/drift/`             | `@DriftDatabase(include: {'…drift'})`, Dart-only tables with FK, `@DriftAccessor` DAO, `TypeConverter`, multi-table joins via both Dart DSL and `.drift` named queries |
| `stacked` / `stacked_generator` (6 sub-builders) | `e2e/examples/builders/stacked/`           | `@StackedApp` → locator (behavioral) + router/dialog/bottomsheet/logger (structural); `@FormView` → form (structural)                                                  |

Cross-cutting scenarios that aren't tied to a single builder:

| Exemplar                                  | What it demonstrates                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `e2e/examples/builders/cascade_two_stage/`     | Multi-annotation chain on one file (freezed → json cascade); DAG topological ordering + combining integration |
| `e2e/examples/builders/multi_shard_combining/` | Multiple SharedPart builders on one source (json + copy_with) merged into one `.g.dart`                       |
| `e2e/examples/builders/source_tree_generated/` | A `.g.dart` checked into the source tree doesn't leak into Bazel runfiles                                    |
| `e2e/examples/builders/unique_extension/`      | A non-SharedPart builder (freezed's `.freezed.dart`) through a bare `dart_codegen`, with no combining step     |
| `e2e/examples/builders/external_builder/`      | A builder from outside rules_dart: its shim built against its own pub resolution, its macro over `shared_part_codegen` |
