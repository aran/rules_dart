"""Convenience macro for drift_dev.

Implements the upstream `drift_dev` 4-stage Builder pipeline on top of
the rules_dart shim-contract primitives:

  1. `shim_prep` (`PreprocessBuilder`) — runs on each `.drift`/`.moor`;
     emits `.drift_prep.json` + `.expr.temp.dart`.
  2. `shim_discover` (`DriftDiscover`) — runs on each `.drift`/`.moor`;
     emits `.drift.drift_elements.json`. Consumed by drift's
     `BuildCacheReader.readDiscovery` (keyed on `.drift_elements.json`).
  3. `shim_analyzer` (`DriftAnalyzer`) — runs on each `.drift`/`.moor`;
     emits `.drift.drift_module.json` + `.drift.types.temp.dart`.
     Consumed by `BuildCacheReader.readElementCacheFor`.
  4. `shim_drift` (`[discover, analyzer, driftBuilder]`) — runs on each
     `.dart` source; emits `.drift.g.part` (SharedPart shard). The dart
     side runs discover+analyzer in-memory; the per-`.drift`-file stages
     above are required so that `@DriftDatabase(include: {'file.drift'})`
     finds the cached discovery/analysis when the driver's
     `findsLocalElementsReliably` is true.

After shim_drift, the combining shim merges the `.g.part` shard into
`.g.dart`. Pass empty `drift_srcs` for Dart-only setups — stages 1–3 are
skipped entirely.
"""

load(
    "@rules_dart//dart:defs.bzl",
    "dart_codegen",
    "dart_library",
    "dart_sqlcodegen",
)

def _token(s):
    t = s
    if t.startswith("//"):
        t = t[2:]
    if ":" in t:
        t = t.split(":")[-1]
    return t.replace("/", "_").replace(".", "_").replace("-", "_")

def drift_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        drift_srcs = [],
        deps = [],
        annotation_dep = "@pub_deps//:drift",
        **kwargs):
    """A dart_library augmented by drift_dev's full multi-stage codegen.

    Args:
      name: Wrapping `dart_library` target name.
      srcs: `.dart` source files carrying `@DriftDatabase` / `@DriftAccessor`
        annotations.
      package_name: Dart package name.
      language_version: Dart language version (`<major>.<minor>`).
      drift_srcs: Optional `.drift` / `.moor` schema files. Each goes
        through prep + discover + analyzer so drift's `BuildCacheReader`
        can satisfy `readDiscovery` / `readElementCacheFor` when the main
        builder resolves `include:` / cross-file references.
      deps: Additional `dart_library`-shaped targets; `annotation_dep` is
        added automatically.
      annotation_dep: Runtime drift library label.
      **kwargs: Forwarded to the wrapping `dart_library`.
    """
    effective_deps = deps + [annotation_dep]

    # Stage 1: PreprocessBuilder per `.drift`/`.moor`.
    # Upstream declares BOTH outputs — `.drift_prep.json` (consumed by
    # `BuildCacheReader.readDiscovery` fallback / `readPreprocessed`) AND
    # `.expr.temp.dart` (consumed by `backend.dart`'s expression-helper
    # lookup at `canRead('.expr.temp.dart')`). Declaring only one would
    # silently drop the other.
    prep_targets = []
    for drift_src in drift_srcs:
        prep_target = "_{name}_{token}_prep".format(
            name = name,
            token = _token(drift_src),
        )
        dart_sqlcodegen(
            name = prep_target,
            src = drift_src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_prep",
            output_suffixes = [".drift_prep.json", ".expr.temp.dart"],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps,
        )
        prep_targets.append(":" + prep_target)

    # Stage 2: DriftDiscover per `.drift`/`.moor` — emits the
    # `.drift.drift_elements.json` cache file that `BuildCacheReader`
    # keys `readDiscovery` on. Needed for `include:` resolution.
    discover_targets = []
    for drift_src in drift_srcs:
        discover_target = "_{name}_{token}_discover".format(
            name = name,
            token = _token(drift_src),
        )
        dart_sqlcodegen(
            name = discover_target,
            src = drift_src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_discover",
            output_suffixes = [".drift.drift_elements.json"],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps,
            asset_deps = drift_srcs + prep_targets,
        )
        discover_targets.append(":" + discover_target)

    # Cross-source visibility for the DriftBuilder stage. When a project
    # splits @DriftDatabase and @DriftAccessor across multiple .dart files
    # (the common DAO-in-its-own-file pattern), drift_dev running on any
    # one file needs the other files visible through the Resolver to
    # resolve cross-file type references like `DatabaseAccessor<AppDatabase>`.
    # Wrap the user's Dart srcs in a source-only `dart_library` so each
    # per-src codegen sees the siblings via `same_package_library_dep_files`
    # auto-staging.
    siblings_lib = "_{}_siblings".format(name)
    dart_library(
        name = siblings_lib,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        visibility = ["//visibility:private"],
    )

    # Discover per `.dart`. `@DriftDatabase(include: {'foo.drift'})` combined
    # with the reverse — a `.drift` file's `import 'bar.dart';` referencing
    # Dart-defined tables — requires each side's discover results to be
    # available before either's analyzer runs, so we emit the `.dart`
    # discover in parallel with the `.drift` discover and feed BOTH into
    # every analyzer stage below.
    dart_discover_targets = []
    for src in srcs:
        t = _token(src)
        dart_discover_target = "_{name}_{token}_dart_discover".format(
            name = name,
            token = t,
        )
        dart_codegen(
            name = dart_discover_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_discover",
            output_suffixes = [".dart.drift_elements.json"],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps + [":" + siblings_lib],
            asset_deps = drift_srcs + prep_targets + discover_targets,
        )
        dart_discover_targets.append(":" + dart_discover_target)

    # DriftAnalyzer per `.dart` — emits `.dart.drift_module.json`. Must
    # run BEFORE the `.drift` analyzer because a `.drift` file that
    # `import`s a `.dart` file resolves cross-file table references via
    # `BuildCacheReader.readStoredAnalysisResult`, which reads this JSON.
    # Without the Dart analyzer's output in scope, drift falls back to a
    # fresh rediscovery pass inside the `.drift` analyzer run and fails
    # to locate elements by id — the visible symptom is
    # `DriftResolver._restoreOrResolve` throwing `"Bad state: No element"`
    # on `.drift` queries that reference Dart-defined tables.
    dart_analyzer_targets = []
    for src in srcs:
        t = _token(src)
        dart_analyzer_target = "_{name}_{token}_dart_analyzer".format(
            name = name,
            token = t,
        )
        dart_codegen(
            name = dart_analyzer_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_analyzer",
            output_suffixes = [
                ".dart.drift_module.json",
                ".dart.types.temp.dart",
            ],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps + [":" + siblings_lib],
            asset_deps = (
                drift_srcs + prep_targets + discover_targets +
                dart_discover_targets
            ),
        )
        dart_analyzer_targets.append(":" + dart_analyzer_target)

    # DriftAnalyzer per `.drift`/`.moor` — emits `.drift.drift_module.json`
    # (element cache) + `.drift.types.temp.dart` (type helpers). Cross-
    # references Dart-defined tables via the Dart-side analyzer output,
    # so its asset_deps must include both Dart discover AND Dart analyzer
    # outputs.
    analyzer_targets = []
    for drift_src in drift_srcs:
        analyzer_target = "_{name}_{token}_analyzer".format(
            name = name,
            token = _token(drift_src),
        )
        dart_sqlcodegen(
            name = analyzer_target,
            src = drift_src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_analyzer",
            output_suffixes = [
                ".drift.drift_module.json",
                ".drift.types.temp.dart",
            ],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps,
            asset_deps = (
                drift_srcs + prep_targets + discover_targets +
                dart_discover_targets + dart_analyzer_targets
            ),
        )
        analyzer_targets.append(":" + analyzer_target)

    drift_side_outputs = (
        drift_srcs + prep_targets + discover_targets + analyzer_targets +
        dart_discover_targets + dart_analyzer_targets
    )

    # Stage 4: DriftBuilder on `.dart` → `.drift.g.part` SharedPart shard.
    # The shim also runs discover+analyzer in-memory on the .dart input
    # (via shimMain's multi-factory form) so the dart side doesn't need
    # separate action-level stages. But it consults the per-.drift-file
    # cache files produced above via `findAssets` when resolving
    # `include:` and the per-`.dart` cache files when resolving
    # cross-file DAO references.
    combined_targets = []
    for src in srcs:
        token = _token(src)
        part_target = "_{name}_{token}_part".format(
            name = name,
            token = token,
        )
        combined_target = "_{name}_{token}_combined".format(
            name = name,
            token = token,
        )
        dart_codegen(
            name = part_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/drift:shim_drift",
            output_suffixes = [".drift.g.part"],
            package_name = package_name,
            language_version = language_version,
            deps = effective_deps + [":" + siblings_lib],
            asset_deps = drift_side_outputs,
        )

        # Stage 5: combining shim → `.g.dart`.
        dart_codegen(
            name = combined_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/_shared/combining_shim:bin",
            output_suffixes = [".g.dart"],
            parts = [":" + part_target],
            package_name = package_name,
            language_version = language_version,
        )
        combined_targets.append(":" + combined_target)

    dart_library(
        name = name,
        srcs = srcs + combined_targets,
        deps = effective_deps,
        package_name = package_name,
        language_version = language_version,
        **kwargs
    )
