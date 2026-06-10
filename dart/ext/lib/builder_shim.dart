/// Shim-runner: turns a single `package:build` Builder into a CLI tool that
/// matches the `dart_codegen` rule's `--input` / `--output` contract.
///
/// Per-builder shim binaries import this library and call [runShim] in their
/// `main()`. The generic plumbing (arg parsing, in-memory asset reader/writer,
/// analyzer-driven Resolver, BuildStep adapter) lives here; per-builder shims
/// stay ~10 lines.
///
/// The shim depends only on `package:build` (interfaces) and `package:analyzer`
/// (resolver). `build_resolvers` and `build_runner_core` were both
/// discontinued; their resolver/runBuilder functionality is reimplemented
/// here over the public analyzer API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:args/args.dart';
import 'package:build/build.dart';
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// Parsed shim CLI arguments.
class ShimArgs {
  ShimArgs({
    required this.inputPath,
    required this.inputAssetPath,
    required this.outputPaths,
    required this.packageName,
    required this.depPaths,
    required this.config,
    required this.rootLanguageVersion,
    this.packageConfigUri,
    this.sdkPath,
  });

  final String inputPath;

  /// In-package path (e.g. `lib/src/models/user.dart`); preserves subdirs
  /// that `p.basename(inputPath)` would drop.
  final String inputAssetPath;

  /// Declared Bazel output paths (one per builder-produced extension).
  /// The shim routes each builder-emitted asset to the matching declared
  /// path by suffix; any declared path with no emitted asset is written
  /// via the per-shim [EmptyOutputHook] fallback.
  final List<String> outputPaths;
  final String packageName;

  /// Pairs of `(exec_path, in_package_asset_path)`.
  final List<({String exec, String asset})> depPaths;

  final Map<String, dynamic> config;

  /// Path to a `package_config.json`; null falls back to `Isolate.packageConfig`.
  final String? packageConfigUri;

  /// Dart SDK root — AOT shims can't auto-detect this.
  final String? sdkPath;

  final LanguageVersion rootLanguageVersion;

  factory ShimArgs.parse(List<String> argv) {
    final parser = ArgParser()
      ..addOption('input', help: 'Input file exec-root path.', mandatory: true)
      ..addMultiOption(
        'output',
        help:
            'Declared output file path (repeatable). Each builder-'
            'produced asset is routed to the declared output whose '
            'basename shares the input stem + matching suffix. At least '
            'one `--output` is required.',
      )
      ..addOption(
        'input-asset',
        help:
            'Asset path for the input within its package, relative to the '
            "package root (e.g. `lib/src/models/user.dart`). Preserves "
            "subdirectory structure that `p.basename(--input)` would drop. "
            "Required.",
        mandatory: true,
      )
      ..addOption(
        'package',
        help:
            'Owning Dart package name (matches consumer pubspec `name:`). '
            'Required — the shim builds AssetIds from this.',
        mandatory: true,
      )
      ..addMultiOption(
        'dep',
        help:
            'Additional source file visible to the Resolver. '
            'Format: `<exec_path>|<asset_path>` (asset path is the path '
            'within the owning package, e.g. `lib/base.dart`). Repeatable.',
      )
      ..addMultiOption(
        'input-asset-extra',
        help:
            'Extra aggregate inputs beyond the primary `--input`. Same '
            '`<exec>|<asset>` form as `--dep`, but these are exposed to '
            'the Builder as primary asset inputs (used by aggregate / '
            'PackageBuilder-style shims). Repeatable.',
      )
      ..addOption(
        'config',
        help: 'Builder options as JSON. Defaults to "{}".',
        defaultsTo: '{}',
      )
      ..addOption(
        'package-config',
        help:
            'Path to package_config.json for third-party import resolution. '
            "Defaults to the running process's package_config.",
        defaultsTo: '',
      )
      ..addOption(
        'root-language-version',
        help:
            'Dart language version (in `<major>.<minor>` form) for the '
            'root package, propagated from the consuming dart_library. '
            'Required — no default.',
        mandatory: true,
      )
      ..addOption(
        'sdk-path',
        help:
            'Path to the Dart SDK installation root (the directory '
            'containing `lib/_internal/libraries.dart`). Required when '
            "the shim runs as an AOT-compiled binary so the analyzer's "
            "context collection can locate the SDK's libraries. The "
            "rules_dart codegen rules pass this from the toolchain.",
        defaultsTo: '',
      );

    final ArgResults parsed;
    try {
      parsed = parser.parse(argv);
    } on ArgParserException catch (e) {
      throw FormatException(
        'Invalid shim arguments: ${e.message}\n${parser.usage}',
      );
    }

    if (parsed.rest.isNotEmpty) {
      throw FormatException(
        'Unexpected positional arguments: ${parsed.rest}\n${parser.usage}',
      );
    }

    // Mandatory options in the `args` package throw ArgumentError on read
    // when absent. Wrap every mandatory read and surface as FormatException
    // so callers get a consistent error type.
    final String input;
    final List<String> outputs;
    final String inputAsset;
    final String pkg;
    final String rootLvRaw;
    try {
      input = parsed['input'] as String;
      outputs = (parsed['output'] as List).cast<String>();
      inputAsset = parsed['input-asset'] as String;
      pkg = parsed['package'] as String;
      rootLvRaw = parsed['root-language-version'] as String;
    } on ArgumentError catch (e) {
      throw FormatException('${e.message}\n${parser.usage}');
    }
    if (outputs.isEmpty) {
      throw FormatException(
        'At least one --output is required.\n${parser.usage}',
      );
    }
    final deps = <({String exec, String asset})>[];
    ({String exec, String asset}) parsePipe(String raw, String flag) {
      final sep = raw.indexOf('|');
      if (sep < 0) {
        throw FormatException(
          '$flag must be `<exec_path>|<asset_path>`; got "$raw"',
        );
      }
      return (exec: raw.substring(0, sep), asset: raw.substring(sep + 1));
    }

    for (final d in (parsed['dep'] as List).cast<String>()) {
      deps.add(parsePipe(d, '--dep'));
    }
    // Aggregate-codegen extras are staged identically to deps so the
    // Builder sees them via AssetReader / findAssets.
    for (final e in (parsed['input-asset-extra'] as List).cast<String>()) {
      deps.add(parsePipe(e, '--input-asset-extra'));
    }
    final configJson = parsed['config'] as String;
    final pkgConfig = parsed['package-config'] as String;
    final sdkPath = parsed['sdk-path'] as String;
    final rootLvParts = rootLvRaw.split('.');
    if (rootLvParts.length != 2) {
      throw FormatException(
        '--root-language-version must be `<major>.<minor>`, got '
        '"$rootLvRaw"',
      );
    }
    final rootLvMajor = int.tryParse(rootLvParts[0]);
    final rootLvMinor = int.tryParse(rootLvParts[1]);
    if (rootLvMajor == null ||
        rootLvMinor == null ||
        rootLvMajor < 0 ||
        rootLvMinor < 0) {
      throw FormatException(
        '--root-language-version components must be non-negative ints, '
        'got "$rootLvRaw"',
      );
    }
    final rootLv = LanguageVersion(rootLvMajor, rootLvMinor);

    final Map<String, dynamic> config;
    final trimmed = configJson.trim();
    if (trimmed.isEmpty || trimmed == '{}') {
      config = <String, dynamic>{};
    } else {
      Object? decoded;
      try {
        decoded = jsonDecode(configJson);
      } on FormatException catch (e) {
        throw FormatException(
          '--config must be a JSON object string. Parse error: ${e.message}',
        );
      }
      if (decoded is! Map) {
        throw FormatException(
          '--config must be a JSON object (got ${decoded.runtimeType}).',
        );
      }
      config = decoded.map((k, v) => MapEntry(k.toString(), v));
    }

    return ShimArgs(
      inputPath: input,
      inputAssetPath: inputAsset,
      outputPaths: outputs,
      packageName: pkg,
      depPaths: deps,
      config: config,
      packageConfigUri: pkgConfig.isEmpty ? null : pkgConfig,
      sdkPath: sdkPath.isEmpty ? null : sdkPath,
      rootLanguageVersion: rootLv,
    );
  }
}

/// Signature of a per-shim callback that returns the bytes to write for
/// a declared Bazel output when the Builder emitted nothing (e.g. the
/// source carried no matching annotations). The default is an empty file;
/// injectable's metadata shim returns `[]` (the empty-array JSON).
typedef EmptyOutputHook =
    FutureOr<List<int>> Function(AssetId inputId, String outputExtension);

/// Type alias for a `package:build` Builder factory — a function that
/// constructs a Builder given its BuilderOptions.
typedef BuilderFactory = Builder Function(BuilderOptions options);

/// Runs one or more Builder factories over the inputs described by
/// [argv]. Pass a single [BuilderFactory] for the common one-Builder
/// case, or a list for multi-stage shims (e.g. drift's discover →
/// analyzer → driftBuilder pipeline; all three share one BuildStep).
///
/// Example per-builder shim main:
/// ```dart
/// import 'package:rules_dart_ext/builder_shim.dart';
/// import 'package:json_serializable/builder.dart' show jsonSerializable;
/// Future<void> main(List<String> args) => runShim(args, jsonSerializable);
/// ```
///
/// Multi-stage:
/// ```dart
/// Future<void> main(List<String> args) =>
///     runShim(args, [discover, analyzer, driftBuilder]);
/// ```
///
/// Sets `exitCode` to 0 on success, 1 on builder failure, 2 on argument
/// parsing failure.
Future<void> runShim(
  List<String> argv,
  Object factoryOrFactories, {
  EmptyOutputHook? emptyOutput,
  Directory? stagingRoot,
  AnalysisContextBuilder? buildAnalysisContext,
  DiagnosticSink? writeDiagnostic,
}) async {
  final sink = writeDiagnostic ?? _stderrSink;
  final ShimArgs args;
  try {
    args = ShimArgs.parse(argv);
  } on FormatException catch (e) {
    sink(e.message);
    exitCode = 2;
    return;
  }
  try {
    final absArgs = _absoluteArgs(args);
    final stagingDir = await (stagingRoot ?? Directory.systemTemp).createTemp(
      'shim_${args.packageName}_',
    );
    final originalCwd = Directory.current;
    try {
      await prepareSourceGenCwd(
        baseDir: stagingDir,
        packageName: args.packageName,
      );
      await _runWithStaging(
        absArgs,
        _normaliseFactories(factoryOrFactories),
        stagingDir,
        emptyOutput: emptyOutput,
        buildAnalysisContext: buildAnalysisContext,
        writeDiagnostic: sink,
      );
    } finally {
      Directory.current = originalCwd;
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    }
  } catch (e, st) {
    sink('Builder failed for ${args.inputPath}: $e');
    sink(st.toString());
    exitCode = 1;
  }
}

/// Receives per-request diagnostic lines. One-shot callers use the default
/// (writes to the process stderr). Worker-mode callers pass a closure that
/// appends to `WorkResponse.output` so diagnostics surface in Bazel's
/// action-failure output instead of the shared worker stderr.
typedef DiagnosticSink = void Function(String message);

void _stderrSink(String message) => stderr.writeln(message);

List<BuilderFactory> _normaliseFactories(Object factoryOrFactories) {
  if (factoryOrFactories is BuilderFactory) return [factoryOrFactories];
  if (factoryOrFactories is List) {
    return factoryOrFactories.cast<BuilderFactory>();
  }
  throw ArgumentError(
    'runShim expects a BuilderFactory or List<BuilderFactory>, got '
    '${factoryOrFactories.runtimeType}',
  );
}

/// Writes a `pubspec.yaml` in [baseDir] and chdirs into it, so `source_gen`'s
/// `rootPackageName` (a CWD-reading top-level `final`) initialises correctly
/// before any Builder runs.
///
/// Also drops an empty `stacked.json` so `stacked_generator`'s
/// `ConfigHelper.composeAndLoadConfigFile()` — invoked unconditionally
/// by its dialog + bottomsheet generators via `getStackedAppFileName()`
/// — finds the config file it hard-codes at CWD and loads its defaults
/// silently. Without this the helper hits a `PathNotFoundException` and
/// writes a diagnostic to stdout, which corrupts Bazel's worker
/// protocol. An empty JSON object is the sentinel that means "use
/// defaults"; benign for non-stacked builders.
Future<void> prepareSourceGenCwd({
  required Directory baseDir,
  required String packageName,
}) async {
  await baseDir.create(recursive: true);
  await File(
    p.join(baseDir.absolute.path, 'pubspec.yaml'),
  ).writeAsString('name: $packageName\nenvironment:\n  sdk: ^3.0.0\n');
  await File(
    p.join(baseDir.absolute.path, 'stacked.json'),
  ).writeAsString('{}\n');
  Directory.current = baseDir;
}

/// Same as [runShim] but takes pre-parsed [args] and propagates errors as
/// exceptions. Intended for unit tests.
Future<void> runShimWithArgs(
  ShimArgs args,
  Object factoryOrFactories, {
  EmptyOutputHook? emptyOutput,
}) async {
  // Relative paths in `args` are resolved against the process CWD. We
  // chdir into the staging dir below for source_gen's benefit, so resolve
  // everything up-front here; after chdir, any still-relative path would
  // resolve against the staging dir and break.
  final absArgs = _absoluteArgs(args);
  final stagingDir = await Directory.systemTemp.createTemp(
    'shim_${args.packageName}_',
  );
  final originalCwd = Directory.current;
  try {
    await prepareSourceGenCwd(
      baseDir: stagingDir,
      packageName: args.packageName,
    );
    await _runWithStaging(
      absArgs,
      _normaliseFactories(factoryOrFactories),
      stagingDir,
      emptyOutput: emptyOutput,
    );
  } finally {
    Directory.current = originalCwd;
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
  }
}

/// Absolute + normalized path. The normalize is critical on Windows: paths
/// arrive from Bazel using `/` separators, but `p.absolute` only prefixes
/// the cwd (with native `\`) without normalizing the remainder, leaving
/// mixed-separator paths that `package:build`'s path validator rejects
/// with "Only absolute normalized paths are supported". On POSIX,
/// `p.normalize` is a no-op for already-clean paths.
String _absAndNormalize(String path) => p.normalize(p.absolute(path));

/// Native on-disk path for a POSIX `AssetId` path under a native staging dir.
///
/// `assetPath` is a `package:build` `AssetId` path — always `/`-separated. The
/// staging dir is native. The correct url→native conversion splits the asset in
/// the posix context and re-joins the segments in [ctx] (the platform context in
/// production): a plain `p.join(nativeDir, posixPath)` leaves the asset's inner
/// `/` untouched, yielding a mixed-separator path the analyzer rejects on Windows
/// (`NotPathOfUriResult`). [ctx] is injected so this is host-testable per platform.
String stagedPath(p.Context ctx, String stagingDir, String assetPath) =>
    ctx.joinAll([stagingDir, ...p.posix.split(assetPath)]);

ShimArgs _absoluteArgs(ShimArgs a) => ShimArgs(
  inputPath: _absAndNormalize(a.inputPath),
  inputAssetPath: a.inputAssetPath,
  outputPaths: [for (final o in a.outputPaths) _absAndNormalize(o)],
  packageName: a.packageName,
  depPaths: [
    for (final d in a.depPaths)
      (exec: _absAndNormalize(d.exec), asset: d.asset),
  ],
  config: a.config,
  packageConfigUri: a.packageConfigUri != null
      ? _absAndNormalize(a.packageConfigUri!)
      : null,
  sdkPath: a.sdkPath != null ? _absAndNormalize(a.sdkPath!) : null,
  rootLanguageVersion: a.rootLanguageVersion,
);

/// Extracts the value of a `--<flag>` argument from a raw argv list (or
/// null if absent). Useful for shim entrypoints that wrap [runShim] and
/// need to post-process the declared output path.
String? extractShimFlag(List<String> argv, String flag) {
  for (var i = 0; i < argv.length - 1; i++) {
    if (argv[i] == flag) return argv[i + 1];
    if (argv[i].startsWith('$flag=')) {
      return argv[i].substring(flag.length + 1);
    }
  }
  return null;
}

/// Signature of a function that returns an [AnalysisContextCollection]
/// for the given inclusion + SDK settings. Tests can inject a stub; the
/// shim's default is [_defaultBuildAnalysisContext].
typedef AnalysisContextBuilder =
    Future<AnalysisContextCollection> Function({
      required List<String> includedPaths,
      required String? sdkPath,
    });

Future<AnalysisContextCollection> _defaultBuildAnalysisContext({
  required List<String> includedPaths,
  required String? sdkPath,
}) async =>
    AnalysisContextCollection(includedPaths: includedPaths, sdkPath: sdkPath);

Future<void> _runWithStaging(
  ShimArgs args,
  List<Builder Function(BuilderOptions)> builderFactories,
  Directory stagingDir, {
  EmptyOutputHook? emptyOutput,
  AnalysisContextBuilder? buildAnalysisContext,
  DiagnosticSink writeDiagnostic = _stderrSink,
}) async {
  // Paths in [args] are pre-absolutised by _absoluteArgs so the chdir below
  // doesn't invalidate them.
  final stagingPath = stagingDir.absolute.path;
  final absOutputPaths = args.outputPaths;
  final absInputExec = args.inputPath;

  // Dedup by asset path before staging. The same logical file can arrive via
  // more than one exec path — the input is also listed among the deps (e.g.
  // drift passes the `.drift` src in `asset_deps`), and a co-located package
  // may surface a file both as a source and as its bazel-out copy. Staging the
  // same asset twice races to one dest: a harmless overwrite on POSIX, but a
  // hard error on Windows (`File.copy` won't overwrite). The input asset wins.
  final execByAsset = <String, String>{args.inputAssetPath: absInputExec};
  for (final dep in args.depPaths) {
    execByAsset.putIfAbsent(dep.asset, () => dep.exec);
  }

  // Same-package deps land in the synthetic root; cross-package deps need
  // a PackageConfig entry (currently unsupported).
  final assetIdToPath = <AssetId, String>{};
  await Future.wait(
    execByAsset.entries.map((entry) async {
      final dest = stagedPath(p.context, stagingPath, entry.key);
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(entry.value).copy(dest);
      assetIdToPath[AssetId(args.packageName, entry.key)] = dest;
    }),
  );
  final inputId = AssetId(args.packageName, args.inputAssetPath);

  // Build a PackageConfig that maps the synthetic root package to the
  // staging dir, and merges in every package from the upstream config so
  // third-party `package:` imports resolve.
  final packageConfig = await _buildPackageConfig(args, stagingDir);

  // Write `.dart_tool/package_config.json` so the AnalysisContextCollection
  // picks it up via Dart's standard package-resolution lookup.
  final dartTool = Directory(p.join(stagingPath, '.dart_tool'));
  await dartTool.create();
  final pcFile = File(p.join(dartTool.path, 'package_config.json'));
  await pcFile.writeAsString(_serializePackageConfig(packageConfig));

  // Write a minimal pubspec.yaml so the analyzer recognises the staging
  // dir as a Dart package root. Also satisfies source_gen's
  // `rootPackageName` (a top-level `final` in `source_gen/src/utils.dart`
  // that reads `pubspec.yaml` from CWD) — the workerEntry pre-writes this
  // file at startup via [prepareSourceGenCwd] so the cache is populated
  // before any Builder observes it.
  await File(
    p.join(stagingPath, 'pubspec.yaml'),
  ).writeAsString('name: ${args.packageName}\nenvironment:\n  sdk: ^3.0.0\n');

  // Include ONLY the staging dir. Cross-package imports (`package:drift/...`,
  // `package:json_annotation/...`, …) are resolved through the
  // package_config.json we wrote above — the analyzer loads pub-cache
  // libraries lazily, but into the SAME AnalysisContext as the user's
  // code so their element models share one identity space.
  //
  // Previously we listed every pub-cache package root in `includedPaths`.
  // That produced one AnalysisContext per root, and a SEPARATE element
  // model per context. Cross-context `asInstanceOf` calls then silently
  // returned null — the visible symptom was drift_dev's
  // `readTypeConverter` reporting `"Not a type converter"` on a
  // `.map(const MyConverter())` expression whose static type resolved
  // (from the staging context) to a `MyConverter` element whose
  // `TypeConverter` supertype was NOT identical to the `TypeConverter`
  // element drift loaded via `backend.readDart(drift2Uri)` (from the
  // drift pub-cache context). Forcing one context canonicalises them.
  final contextBuilder = buildAnalysisContext ?? _defaultBuildAnalysisContext;
  final collection = await contextBuilder(
    includedPaths: [stagingPath],
    sdkPath: args.sdkPath != null ? p.absolute(args.sdkPath!) : null,
  );

  // CWD must contain a valid pubspec before any Builder runs; the shim
  // entry pre-populates it via [prepareSourceGenCwd].
  final writer = _ShimAssetWriter();
  final reader = _ShimAssetReader(assetIdToPath, packageConfig, writer);
  final resolver = _ShimAnalyzerResolver(
    collection,
    assetIdToPath,
    packageConfig,
  );

  // The last Builder's allowedOutputs are derived from the rule-declared
  // `--output` paths (one AssetId per declared file, placed in the input's
  // directory). This makes the rule layer authoritative: users control the
  // Bazel output filenames via `output_suffixes` / `outputs`, and the
  // builder writes to whatever the rule declared — regardless of any
  // name the Builder's internal `buildExtensions` map might suggest.
  // (`SharedPartBuilder('copyWith', ...)` internally sets
  // `.copyWith.g.part`, but build_runner and build.yaml override it to
  // `copy_with_extension_gen.g.part`; rules_dart takes that same approach
  // by letting the declared outputs win.)
  //
  // Earlier Builders in multi-stage pipelines keep their own
  // `buildExtensions`-derived allowedOutputs so findAssets sees
  // intermediate writes.
  final builders = builderFactories
      .map((f) => f(BuilderOptions(args.config)))
      .toList();
  final allowedOutputs = _allowedOutputsFromDeclaredPaths(
    inputId,
    absOutputPaths,
  );

  // Wire a Logger listener so Builder-emitted warnings/errors reach the
  // diagnostic sink; without this, `package:build`'s `log` sinks into a
  // silent fallback.
  final originalLevel = Logger.root.level;
  final logger = Logger('rules_dart_ext');
  final logSub = Logger.root.onRecord.listen((rec) {
    writeDiagnostic(
      '[${rec.level.name}] ${rec.loggerName}: ${rec.message}'
      '${rec.error != null ? " error=${rec.error}" : ""}'
      '${rec.stackTrace != null ? "\n${rec.stackTrace}" : ""}',
    );
  });
  // Track every _ShimBuildStep so multi-stage pipelines dispose each
  // stage's ResourceManager (not just the last one) on completion.
  final steps = <_ShimBuildStep>[];
  final lastIndex = builders.length - 1;
  try {
    // Set the level inside the try so the `finally` below always
    // restores it — even if anything between here and the `for` loop
    // throws. Builders that elevate the root level (for their own
    // diagnostics) can't poison later worker requests.
    Logger.root.level = Level.WARNING;
    for (var i = 0; i < builders.length; i++) {
      final builder = builders[i];
      final allowedForThisStep = i == lastIndex
          ? allowedOutputs
          : _expectedOutputsFor(inputId, builder.buildExtensions);
      final step = _ShimBuildStep(
        inputId: inputId,
        reader: reader,
        writer: writer,
        resolver: resolver,
        allowedOutputsValue: allowedForThisStep,
        packageConfig: packageConfig,
      );
      steps.add(step);
      // Run each Builder in a zone where `package:build`'s `log` resolves
      // to our listener-equipped Logger (see the `logKey` constant in
      // `package:build/src/logging.dart`).
      await runZoned(
        () => builder.build(step),
        zoneValues: {#buildLog: logger},
      );
    }
  } finally {
    // Drain any Resources a Builder held via `fetchResource` so they don't
    // leak across sequential worker requests. Disposal-phase log records
    // still flow to the listener because we cancel *after* disposal.
    for (final step in steps) {
      try {
        await step._resourceManager.disposeAll();
      } catch (e, st) {
        writeDiagnostic('ResourceManager.disposeAll failed: $e\n$st');
      }
    }
    await logSub.cancel();
    Logger.root.level = originalLevel;
    // Release analyzer drivers, file-watching handles, and thread-pool
    // workers. Without this, a long-running worker accumulates drivers
    // across every request until it exhausts file descriptors.
    try {
      await collection.dispose();
    } catch (_) {
      // Older analyzer releases don't expose dispose; swallow so we don't
      // regress workers on versions that lack it.
    }
  }

  // Route each builder-emitted asset to the declared Bazel output file
  // whose basename matches the same `input_stem + <extension>` pattern.
  // Multi-output builders (e.g. injectable_config_builder emitting both
  // `.config.dart` and `.module.dart`) declare one `--output` per extension
  // and the shim writes each emitted asset to the correct declared path.
  // For multi-stage pipelines we only care about the last (primary)
  // Builder's outputs; anything else is an intermediate from an earlier
  // stage visible only via `findAssets`.
  final allowedSet = allowedOutputs.toSet();
  final emitted = <AssetId, List<int>>{
    for (final e in writer.assets.entries)
      if (allowedSet.contains(e.key)) e.key: e.value,
  };

  final claimed = <AssetId>{};
  for (final outPath in absOutputPaths) {
    final match = _matchEmittedAssetFor(outPath, inputId, emitted, claimed);
    late final List<int> bytes;
    if (match != null) {
      claimed.add(match);
      bytes = emitted[match]!;
    } else {
      // No matching emission — provide the empty-output sentinel (builder
      // saw no relevant annotations). Bazel still requires the declared
      // file to exist.
      final outExt = _outputExtensionFor(inputId, outPath);
      bytes = emptyOutput != null
          ? await emptyOutput(inputId, outExt) as List<int>
          : const <int>[];
    }
    await File(outPath).writeAsBytes(bytes);
  }
}

/// Picks the emitted AssetId from [emitted] that corresponds to the
/// declared Bazel output at [declaredPath], excluding any already-[claimed]
/// matches.
///
/// Matching precedence:
/// 1. Suffix match: the declared file's basename must equal
///    `inputStem + suffix` for some `suffix`, and the emitted AssetId
///    path must equal `inputId.path_stem + suffix`.
/// 2. Basename match: the emitted AssetId's basename equals the declared
///    file's basename (handles builders that rewrite the stem entirely).
///
/// Returns `null` when no unclaimed candidate matches (caller writes the
/// [EmptyOutputHook] sentinel).
AssetId? _matchEmittedAssetFor(
  String declaredPath,
  AssetId inputId,
  Map<AssetId, List<int>> emitted,
  Set<AssetId> claimed,
) {
  final declaredBasename = p.basename(declaredPath);
  final inputStem = p.basenameWithoutExtension(inputId.path);
  if (declaredBasename.startsWith('$inputStem.')) {
    final suffix = declaredBasename.substring(inputStem.length);
    final inputPathStem = inputId.path.substring(
      0,
      inputId.path.length - p.extension(inputId.path).length,
    );
    final candidate = AssetId(inputId.package, '$inputPathStem$suffix');
    if (emitted.containsKey(candidate) && !claimed.contains(candidate)) {
      return candidate;
    }
  }
  for (final id in emitted.keys) {
    if (claimed.contains(id)) continue;
    if (p.basename(id.path) == declaredBasename) return id;
  }
  return null;
}

/// Returns the extension of [outputPath] relative to [inputId]'s stem —
/// e.g. `user.dart` input + `user.g.dart` output → `.g.dart`. Used to
/// pick the right empty-output sentinel.
String _outputExtensionFor(AssetId inputId, String outputPath) {
  final outName = p.basename(outputPath);
  final inStem = p.basenameWithoutExtension(inputId.path);
  if (outName.startsWith('$inStem.')) {
    return outName.substring(inStem.length);
  }
  // Fall back: whatever's after the last dot.
  final dot = outName.indexOf('.');
  return dot < 0 ? '' : outName.substring(dot);
}

/// Builds allowedOutputs AssetIds from the rule-declared `--output` paths.
/// Each declared file maps to an AssetId in the input's directory, named
/// by the file's basename. This is the authoritative allowedOutputs set
/// for the *last* Builder in a pipeline — it overrides whatever
/// `buildExtensions` the Builder class advertises internally, matching
/// build_runner's behavior of letting build.yaml declared extensions win.
Iterable<AssetId> _allowedOutputsFromDeclaredPaths(
  AssetId inputId,
  List<String> declaredPaths,
) {
  final dir = p.posix.dirname(inputId.path);
  return [
    for (final path in declaredPaths)
      AssetId(
        inputId.package,
        dir == '.' ? p.basename(path) : '$dir/${p.basename(path)}',
      ),
  ];
}

/// Derives intermediate AssetIds for a NON-final pipeline stage from the
/// Builder's own `buildExtensions` (final-stage outputs are rule-declared;
/// see `_allowedOutputsFromDeclaredPaths`). Only plain suffix keys are
/// supported: an empty-string key (the PackageBuilder pattern) makes
/// `endsWith('')` always true, and `$lib$`/`$package$` placeholder keys
/// never match a real path suffix — both would silently corrupt the
/// derived AssetId, so they are rejected loudly.
Iterable<AssetId> _expectedOutputsFor(
  AssetId inputId,
  Map<String, List<String>> buildExtensions,
) {
  final outputs = <AssetId>[];
  for (final entry in buildExtensions.entries) {
    final inputExt = entry.key;
    if (inputExt.isEmpty || inputExt.contains(r'$')) {
      throw StateError(
        'buildExtensions key "$inputExt" is unsupported for intermediate '
        'pipeline stages: empty-string keys and \$-placeholder keys '
        '(\$lib\$, \$package\$) cannot be mapped onto an input-relative '
        'AssetId. Final-stage outputs are rule-declared and unaffected; '
        'make this builder the final stage or give it a plain suffix key.',
      );
    }
    if (!inputId.path.endsWith(inputExt)) continue;
    final stem = inputId.path.substring(
      0,
      inputId.path.length - inputExt.length,
    );
    for (final outExt in entry.value) {
      outputs.add(AssetId(inputId.package, '$stem$outExt'));
    }
  }
  return outputs;
}

Future<PackageConfig> _buildPackageConfig(
  ShimArgs args,
  Directory stagingDir,
) async {
  // packageConfigUri may be relative to Bazel's exec root; resolve while
  // we still have the original CWD.
  final upstreamUri = args.packageConfigUri != null
      ? Uri.file(p.absolute(args.packageConfigUri!))
      : await Isolate.packageConfig;
  // If neither the caller nor the running isolate provides a package_config,
  // fall back to an empty one — the synthetic root entry is still added below
  // so builders that only touch the input file (no third-party imports) work.
  final PackageConfig upstream = upstreamUri == null
      ? PackageConfig.empty
      : await loadPackageConfigUri(upstreamUri);

  // Synthetic entry for the input's own package, rooted at the staging dir.
  // Prefer the upstream package_config's entry for our package (looked up by
  // name; path-based lookup wouldn't match: upstream points at the consumer's
  // sources, not our staging dir). Fall back to the explicit
  // --root-language-version flag.
  final rootDir = Uri.directory(stagingDir.absolute.path);
  final upstreamRoot = upstream[args.packageName];
  final rootLanguageVersion =
      upstreamRoot?.languageVersion ?? args.rootLanguageVersion;
  final synthetic = Package(
    args.packageName,
    rootDir,
    packageUriRoot: rootDir.resolve('lib/'),
    languageVersion: rootLanguageVersion,
  );

  return PackageConfig([
    synthetic,
    for (final pkg in upstream.packages)
      if (pkg.name != args.packageName) pkg,
  ]);
}

String _serializePackageConfig(PackageConfig config) {
  final entries = <Map<String, dynamic>>[];
  for (final pkg in config.packages) {
    // `packageUri` is the `packageUriRoot` expressed as a URI relative to
    // `rootUri`. Almost every pub package uses `lib/`, but some workspace
    // layouts (or the synthetic root for the shim's own staging dir) set
    // it differently. Compute it from the Package rather than hardcoding.
    var packageUri = pkg.packageUriRoot.toString();
    final rootUri = pkg.root.toString();
    if (packageUri.startsWith(rootUri)) {
      packageUri = packageUri.substring(rootUri.length);
      if (!packageUri.endsWith('/')) packageUri = '$packageUri/';
      if (packageUri.isEmpty) packageUri = './';
    } else {
      packageUri = 'lib/';
    }
    final entry = <String, dynamic>{
      'name': pkg.name,
      'rootUri': rootUri,
      'packageUri': packageUri,
    };
    final lv = pkg.languageVersion;
    if (lv != null) {
      entry['languageVersion'] = '${lv.major}.${lv.minor}';
    }
    entries.add(entry);
  }
  return const JsonEncoder.withIndent(
    '  ',
  ).convert({'configVersion': 2, 'packages': entries});
}

// ---------------------------------------------------------------------------
// AssetReader implementation.
// ---------------------------------------------------------------------------

/// AssetReader backed by a Map<AssetId, file path> plus the shim's
/// in-memory writer (so multi-stage pipelines can read prior stages'
/// outputs via `findAssets`/`readAsString`).
class _ShimAssetReader extends AssetReader {
  _ShimAssetReader(this._assetIdToPath, this._packageConfig, this._writer);

  final Map<AssetId, String> _assetIdToPath;
  final PackageConfig _packageConfig;
  final _ShimAssetWriter _writer;

  String? _pathFor(AssetId id) {
    final direct = _assetIdToPath[id];
    if (direct != null) return direct;
    // Fall through: look up via the PackageConfig (e.g. for transitively-
    // imported third-party files the analyzer queries). `lib/` paths resolve
    // against `packageUriRoot` (which points at the package's `lib/`);
    // anything else (`bin/`, `test/`, `web/`, top-level files like
    // `pubspec.yaml`) resolves against the package root directory.
    final pkg = _packageConfig[id.package];
    if (pkg == null) return null;
    if (id.path.startsWith('lib/')) {
      final rel = id.path.substring(4);
      return p.fromUri(pkg.packageUriRoot.resolve(rel));
    }
    return p.fromUri(pkg.root.resolve(id.path));
  }

  @override
  Future<bool> canRead(AssetId id) async {
    if (_writer.assets.containsKey(id)) return true;
    final path = _pathFor(id);
    return path != null && await File(path).exists();
  }

  @override
  Future<List<int>> readAsBytes(AssetId id) async {
    final fromWriter = _writer.assets[id];
    if (fromWriter != null) return fromWriter;
    final path = _pathFor(id);
    if (path == null) throw AssetNotFoundException(id);
    final f = File(path);
    if (!await f.exists()) throw AssetNotFoundException(id);
    return f.readAsBytes();
  }

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async {
    final fromWriter = _writer.assets[id];
    if (fromWriter != null) return encoding.decode(fromWriter);
    final path = _pathFor(id);
    if (path == null) throw AssetNotFoundException(id);
    final f = File(path);
    if (!await f.exists()) throw AssetNotFoundException(id);
    return f.readAsString(encoding: encoding);
  }

  @override
  Stream<AssetId> findAssets(Glob glob) async* {
    final seen = <AssetId>{};
    for (final id in _assetIdToPath.keys) {
      if (glob.matches(id.path) && seen.add(id)) yield id;
    }
    for (final id in _writer.assets.keys) {
      if (glob.matches(id.path) && seen.add(id)) yield id;
    }
  }

  @override
  Future<Digest> digest(AssetId id) async {
    final sink = AccumulatorSink<Digest>();
    md5.startChunkedConversion(sink)
      ..add(await readAsBytes(id))
      ..add(id.toString().codeUnits)
      ..close();
    return sink.events.first;
  }
}

// ---------------------------------------------------------------------------
// AssetWriter implementation.
// ---------------------------------------------------------------------------

/// In-memory AssetWriter. The shim runner flushes captured outputs to disk
/// after the Builder returns.
class _ShimAssetWriter implements AssetWriter {
  final Map<AssetId, List<int>> assets = {};

  @override
  Future<void> writeAsBytes(AssetId id, FutureOr<List<int>> bytes) async {
    assets[id] = await bytes;
  }

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> contents, {
    Encoding encoding = utf8,
  }) async {
    assets[id] = encoding.encode(await contents);
  }
}

// ---------------------------------------------------------------------------
// BuildStep implementation.
// ---------------------------------------------------------------------------

/// BuildStep adapter wrapping our reader, writer, and resolver. Resource
/// lifecycle, stage tracking, and unused-asset reporting are no-ops.
class _ShimBuildStep implements BuildStep {
  _ShimBuildStep({
    required this.inputId,
    required _ShimAssetReader reader,
    required _ShimAssetWriter writer,
    required _ShimAnalyzerResolver resolver,
    required Iterable<AssetId> allowedOutputsValue,
    required PackageConfig packageConfig,
  }) : _reader = reader,
       _writer = writer,
       _resolver = resolver,
       _allowedOutputs = allowedOutputsValue,
       _packageConfig = packageConfig;

  @override
  final AssetId inputId;

  final _ShimAssetReader _reader;
  final _ShimAssetWriter _writer;
  final _ShimAnalyzerResolver _resolver;
  final Iterable<AssetId> _allowedOutputs;
  final PackageConfig _packageConfig;

  @override
  Resolver get resolver => _resolver;

  @override
  Future<LibraryElement> get inputLibrary => _resolver.libraryFor(inputId);

  @override
  Future<List<int>> readAsBytes(AssetId id) => _reader.readAsBytes(id);

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) =>
      _reader.readAsString(id, encoding: encoding);

  @override
  Future<bool> canRead(AssetId id) => _reader.canRead(id);

  @override
  Stream<AssetId> findAssets(Glob glob) => _reader.findAssets(glob);

  @override
  Future<Digest> digest(AssetId id) => _reader.digest(id);

  @override
  Iterable<AssetId> get allowedOutputs => _allowedOutputs;

  @override
  Future<void> writeAsBytes(AssetId id, FutureOr<List<int>> bytes) =>
      _writer.writeAsBytes(id, bytes);

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> contents, {
    Encoding encoding = utf8,
  }) => _writer.writeAsString(id, contents, encoding: encoding);

  // Per-invocation Resource cache. build_runner uses fetchResource to share
  // state across builders within one build session; per shim invocation we
  // start with a fresh cache, so cross-action sharing isn't possible — but
  // within a single invocation a Builder may legitimately fetchResource
  // multiple times for the same Resource and expect the same instance back.
  final ResourceManager _resourceManager = ResourceManager();

  @override
  Future<T> fetchResource<T>(Resource<T> resource) =>
      _resourceManager.fetch(resource);

  @override
  T trackStage<T>(
    String label,
    T Function() action, {
    bool isExternal = false,
  }) => action();

  @override
  void reportUnusedAssets(Iterable<AssetId> ids) {}

  @override
  Future<PackageConfig> get packageConfig async => _packageConfig;
}

// ---------------------------------------------------------------------------
// Resolver implementation, backed by package:analyzer.
// ---------------------------------------------------------------------------

/// Resolver implementation that delegates to an [AnalysisContextCollection].
/// AssetIds map to staged file paths via [_assetIdToPath]; the analyzer
/// resolves `package:` imports from the staging dir's package_config.
class _ShimAnalyzerResolver implements Resolver {
  _ShimAnalyzerResolver(
    this._collection,
    this._assetIdToPath,
    this._packageConfig,
  );

  final AnalysisContextCollection _collection;
  final Map<AssetId, String> _assetIdToPath;
  final PackageConfig _packageConfig;

  AnalysisSession _sessionFor(String filePath) {
    // All lookups use the single includedPath's context. Only staging is
    // listed in `includedPaths`; pub-cache packages are resolved lazily
    // through that context's package_config so every element lives in
    // one element model. Using `contextFor(filePath)` on a pub-cache path
    // would throw "Unable to find the context to …" because the path
    // isn't inside any included root.
    return _collection.contexts.first.currentSession;
  }

  /// Returns the on-disk path for [id], either from the staged-asset map or
  /// (for third-party packages) by walking the package_config. `lib/` paths
  /// resolve against `packageUriRoot`; anything else resolves against the
  /// package root directory. Returns null only when neither lookup succeeds.
  String? _pathFor(AssetId id) {
    final direct = _assetIdToPath[id];
    if (direct != null) return direct;
    final pkg = _packageConfig[id.package];
    if (pkg == null) return null;
    if (id.path.startsWith('lib/')) {
      final rel = id.path.substring(4);
      return p.fromUri(pkg.packageUriRoot.resolve(rel));
    }
    return p.fromUri(pkg.root.resolve(id.path));
  }

  @override
  Future<bool> isLibrary(AssetId id) async {
    final path = _pathFor(id);
    if (path == null) return false;
    final result = await _sessionFor(path).getResolvedLibrary(path);
    return result is ResolvedLibraryResult;
  }

  @override
  Future<LibraryElement> libraryFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    final path = _pathFor(id);
    if (path == null) {
      throw NonLibraryAssetException(id);
    }
    final session = _sessionFor(path);
    final parsed = session.getParsedUnit(path);
    if (parsed is! ParsedUnitResult || parsed.isPart) {
      throw NonLibraryAssetException(id);
    }
    // For files under `lib/`, resolve by the canonical package: URI so the
    // returned LibraryElement is the same instance the analyzer hands to
    // import chains. File-path resolution produces a separate element model
    // with `file://` URIs, which breaks source_gen's `TypeChecker.fromUrl`
    // comparisons (e.g. drift's `KnownDriftTypes` loads the helper library
    // by URI; its `Table` element's URI must match the `Table` reached via
    // user code's `import 'package:drift/drift.dart'`).
    //
    // For files outside `lib/` (tests, bin/, web/), there's no package: URI,
    // so fall back to resolved-library-by-path. These files are only reached
    // as the build input — nothing imports them via `package:` — so the URI
    // canonicalisation concern doesn't apply.
    if (id.path.startsWith('lib/')) {
      final libResult = await session.getLibraryByUri(id.uri.toString());
      if (libResult is! LibraryElementResult) {
        throw NonLibraryAssetException(id);
      }
      return libResult.element;
    }
    final result = await session.getResolvedLibrary(path);
    if (result is! ResolvedLibraryResult) {
      throw NonLibraryAssetException(id);
    }
    return result.element;
  }

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    final path = _pathFor(id);
    if (path == null) {
      throw NonLibraryAssetException(id);
    }
    final result = _sessionFor(path).getParsedUnit(path);
    if (result is! ParsedUnitResult) {
      throw NonLibraryAssetException(id);
    }
    return result.unit;
  }

  @override
  Stream<LibraryElement> get libraries async* {
    for (final id in _assetIdToPath.keys) {
      try {
        yield await libraryFor(id);
      } on NonLibraryAssetException {
        // Skip non-library assets (e.g. plain text deps).
      }
    }
  }

  @override
  Future<LibraryElement?> findLibraryByName(String libraryName) async {
    // SDK libraries are queryable by Uri ('dart:async') via
    // session.getLibraryByUri. drift's backend calls findLibraryByName with
    // names like 'dart.async' (dotted), so try the dart: form first.
    if (libraryName.startsWith('dart.')) {
      final uri = 'dart:${libraryName.substring(5)}';
      try {
        // Use any context's session — they all share the SDK.
        final session = _collection.contexts.first.currentSession;
        final result = await session.getLibraryByUri(uri);
        if (result is LibraryElementResult) return result.element;
      } on ArgumentError {
        // Malformed URI — fall through to the library scan below.
      } on StateError {
        // Unknown dart: URI — fall through.
      }
      // Anything else (e.g. `InconsistentAnalysisException`, which
      // signals a stale analysis session) propagates — silently masking
      // those would let drift et al. produce silently-wrong code.
    }
    await for (final lib in libraries) {
      if (lib.name == libraryName) return lib;
    }
    return null;
  }

  @override
  Future<AssetId> assetIdForElement(Element element) async {
    final source = element.library?.firstFragment.source;
    if (source == null) {
      throw UnresolvableAssetException(element.toString());
    }
    final uri = source.uri;
    if (uri.scheme == 'package') {
      final segments = uri.pathSegments;
      if (segments.isEmpty) {
        throw UnresolvableAssetException(uri.toString());
      }
      final pkg = segments.first;
      final relPath = p.posix.joinAll(['lib', ...segments.skip(1)]);
      return AssetId(pkg, relPath);
    }
    if (uri.scheme == 'file') {
      // Reverse-map a `file://` URI back to an AssetId by locating the owning
      // package in the PackageConfig. This fires when a builder calls
      // `assetIdForElement` for an element reached through import walking
      // (the primary `libraryFor` path resolves `lib/` inputs via `package:`
      // URIs specifically to avoid this, but elements discovered transitively
      // can still carry `file://` URIs).
      final filePath = p.normalize(p.fromUri(uri));
      for (final pkg in _packageConfig.packages) {
        final libRoot = p.normalize(p.fromUri(pkg.packageUriRoot));
        final rootDir = p.normalize(p.fromUri(pkg.root));
        if (p.isWithin(libRoot, filePath) || p.equals(libRoot, filePath)) {
          final rel = p.posix.joinAll(
            p.split(p.relative(filePath, from: libRoot)),
          );
          return AssetId(pkg.name, p.posix.join('lib', rel));
        }
        if (p.isWithin(rootDir, filePath) || p.equals(rootDir, filePath)) {
          final rel = p.posix.joinAll(
            p.split(p.relative(filePath, from: rootDir)),
          );
          return AssetId(pkg.name, rel);
        }
      }
    }
    throw UnresolvableAssetException(uri.toString());
  }

  @override
  Future<AstNode?> astNodeFor(Fragment fragment, {bool resolve = false}) async {
    // Returns the AST for [fragment] — a CompilationUnit for the defining
    // library fragment, the matching class/method/field/etc declaration for
    // any other fragment. Drift's resolvers (e.g. `DartTableResolver`) cast
    // this to the specific node type (`MethodDeclaration`, `FieldDeclaration`),
    // so returning the wrong subtype surfaces as cast errors during drift
    // analysis.
    //
    // Resolution MUST go through the library's own session via
    // `getResolvedLibraryByElement`: the expressions inside getter/method
    // bodies only pick up `staticType` when the library is resolved through
    // the same session that produced its Element model. A path-based
    // `_sessionFor(path).getResolvedLibrary(path)` lookup is superficially
    // equivalent but the `AnalysisContextCollection` returns a session whose
    // element model can drift from the library's own — the visible symptom is
    // drift_dev's `readTypeConverter` reporting "Not a type converter" on a
    // `.map(const MyConverter())` argument because the Expression's
    // `staticType` comes back null. Matches drift's own `TestBackend`.
    final libFragment = fragment.libraryFragment;
    if (libFragment == null) return null;
    final library = libFragment.element;
    if (resolve) {
      final libResult = await library.session.getResolvedLibraryByElement(
        library,
      );
      if (libResult is! ResolvedLibraryResult) return null;
      if (identical(fragment, libFragment)) {
        final path = libFragment.source.fullName;
        for (final u in libResult.units) {
          if (u.path == path) return u.unit;
        }
        return null;
      }
      return libResult.getFragmentDeclaration(fragment)?.node;
    }
    final path = libFragment.source.fullName;
    final parsedLib = _sessionFor(path).getParsedLibrary(path);
    if (parsedLib is! ParsedLibraryResult) return null;
    if (identical(fragment, libFragment)) {
      for (final u in parsedLib.units) {
        if (u.path == path) return u.unit;
      }
      return null;
    }
    return parsedLib.getFragmentDeclaration(fragment)?.node;
  }
}

// ---------------------------------------------------------------------------
// Local AccumulatorSink (avoiding an explicit dep on `package:convert`).
// ---------------------------------------------------------------------------

class AccumulatorSink<T> implements ChunkedConversionSink<T> {
  final List<T> events = [];
  @override
  void add(T chunk) => events.add(chunk);
  @override
  void close() {}
}
