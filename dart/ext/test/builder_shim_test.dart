import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:build/build.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rules_dart_ext/builder_shim.dart';
import 'package:rules_dart_ext/worker_entry.dart';
import 'package:test/test.dart';

/// Minimum set of args any valid shim invocation must supply. Per-test
/// overrides are appended; omit an arg by not including it in `overrides`
/// and also naming it in a `removed` list (not needed for most tests).
List<String> _baseArgs({
  Map<String, String> overrides = const {},
  List<String> removed = const [],
}) {
  final args = {
    '--input': 'a.dart',
    '--input-asset': 'lib/a.dart',
    '--output': 'a.g.dart',
    '--package': 'p',
    '--root-language-version': '3.11',
  };
  args.addAll(overrides);
  for (final r in removed) {
    args.remove(r);
  }
  return [for (final e in args.entries) ...[e.key, e.value]];
}

/// Stable URI string for a LibraryElement. Used by the Resolver.libraries
/// tests to compare yielded libraries by `package:foo/bar.dart` shape.
String _libUriString(LibraryElement lib) =>
    lib.firstFragment.source.uri.toString();

ShimArgs _shimArgs({
  required String inputPath,
  required String inputAssetPath,
  required String outputPath,
  List<String>? outputPaths,
  String packageName = 'fixture',
  List<({String exec, String asset})> depPaths = const [],
  Map<String, dynamic> config = const {},
  LanguageVersion? rootLanguageVersion,
  String? packageConfigPath,
}) =>
    ShimArgs(
      inputPath: inputPath,
      inputAssetPath: inputAssetPath,
      outputPaths: outputPaths ?? [outputPath],
      packageName: packageName,
      depPaths: depPaths,
      config: config,
      rootLanguageVersion: rootLanguageVersion ?? LanguageVersion(3, 11),
      packageConfigUri: packageConfigPath,
    );

/// Writes a fake foreign Dart package under [root] named [name] with a
/// single library file `lib/<name>.dart` (the conventional public
/// re-export location). Returns the package directory.
///
/// Used by the Resolver.libraries tests to exercise the cross-package
/// fallback without depending on whatever pub graph the test runner's
/// isolate happens to expose.
Directory _writeForeignPackage({
  required Directory root,
  required String name,
  String libBody = 'class Foo {}\n',
}) {
  final pkgDir = Directory(p.join(root.path, '${name}_pkg'))
    ..createSync(recursive: true);
  Directory(p.join(pkgDir.path, 'lib')).createSync(recursive: true);
  File(p.join(pkgDir.path, 'lib', '$name.dart')).writeAsStringSync(libBody);
  return pkgDir;
}

/// Writes a `package_config.json` at [root]/package_config.json that
/// includes [packages] (each a Directory whose name is `<pkg>_pkg`).
/// Returns the file path.
String _writePackageConfig({
  required Directory root,
  required List<Directory> packages,
}) {
  final entries = <Map<String, dynamic>>[];
  for (final pkg in packages) {
    final name = p.basename(pkg.path).replaceAll('_pkg', '');
    entries.add({
      'name': name,
      'rootUri': Uri.directory(pkg.path).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
  }
  final file = File(p.join(root.path, 'package_config.json'));
  file.writeAsStringSync(jsonEncode({
    'configVersion': 2,
    'packages': entries,
  }));
  return file.path;
}

void main() {
  group('stagedPath', () {
    test('joins a POSIX asset under a native Windows dir, no mixed separators',
        () {
      final dest =
          stagedPath(p.windows, r'C:\tmp\shim_x', 'test/nice_mock_test.dart');
      expect(dest, r'C:\tmp\shim_x\test\nice_mock_test.dart');
      expect(dest, isNot(contains('/')));
    });

    test('handles a nested lib/ asset under a native Windows dir', () {
      expect(
        stagedPath(p.windows, r'C:\s', 'lib/src/models/user.dart'),
        r'C:\s\lib\src\models\user.dart',
      );
    });

    test('is a plain join in the posix context', () {
      expect(
        stagedPath(p.posix, '/tmp/shim_x', 'lib/src/a.dart'),
        '/tmp/shim_x/lib/src/a.dart',
      );
    });

    test('the naive p.join leaves the mixed separators we must avoid', () {
      // platform-context join inserts `\` but does not transcode the asset
      // path's inner `/`, producing the mixed path the analyzer rejects.
      expect(
        p.windows.join(r'C:\tmp\shim_x', 'test/nice_mock_test.dart'),
        r'C:\tmp\shim_x\test/nice_mock_test.dart',
      );
    });
  });

  group('ShimArgs.parse', () {
    test('parses the minimal required arg set', () {
      final args = ShimArgs.parse(_baseArgs());
      expect(args.inputPath, 'a.dart');
      expect(args.outputPaths, ['a.g.dart']);
      expect(args.packageName, 'p');
      expect(args.rootLanguageVersion.major, 3);
      expect(args.rootLanguageVersion.minor, 11);
      expect(args.depPaths, isEmpty);
      expect(args.config, isEmpty);
    });

    test('parses repeatable --output (one per declared Bazel output)', () {
      final args = ShimArgs.parse([
        ..._baseArgs(removed: ['--output']),
        '--output', 'a.config.dart',
        '--output', 'a.module.dart',
      ]);
      expect(args.outputPaths, ['a.config.dart', 'a.module.dart']);
    });

    test('--package is required (no silent basename fallback)', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--package'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('--root-language-version is required (no silent 3.0 default)', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--root-language-version'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('--root-language-version rejects malformed input', () {
      expect(
        () => ShimArgs.parse(_baseArgs(
            overrides: {'--root-language-version': 'not-a-version'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(_baseArgs(
            overrides: {'--root-language-version': '3'})),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(_baseArgs(
            overrides: {'--root-language-version': 'abc.def'})),
        throwsA(isA<FormatException>()),
      );
    });

    test('--config rejects non-object JSON', () {
      expect(
        () => ShimArgs.parse(_baseArgs(overrides: {
          '--config': '"a string is not an object"',
        })),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('JSON object'))),
      );
    });

    test('--config rejects malformed JSON', () {
      expect(
        () => ShimArgs.parse(_baseArgs(overrides: {
          '--config': '{not valid',
        })),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('Parse error'))),
      );
    });

    test('parses --config JSON object', () {
      final args = ShimArgs.parse(_baseArgs(overrides: {
        '--config': '{"createFactory": false}',
      }));
      expect(args.config, {'createFactory': false});
    });

    test('parses repeatable --dep (exec|asset form)', () {
      final args = ShimArgs.parse([
        ..._baseArgs(),
        '--dep', 'exec/sibling1.dart|lib/sibling1.dart',
        '--dep', 'exec/sibling2.dart|lib/src/sibling2.dart',
      ]);
      expect(args.depPaths.map((d) => d.exec),
          ['exec/sibling1.dart', 'exec/sibling2.dart']);
      expect(args.depPaths.map((d) => d.asset),
          ['lib/sibling1.dart', 'lib/src/sibling2.dart']);
    });

    test('--dep without pipe separator rejected', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), '--dep', 'no-pipe.dart']),
        throwsA(isA<FormatException>()),
      );
    });

    test('--input-asset is required', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--input-asset'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unknown flags', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), '--bogus', 'x']),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects positional args', () {
      expect(
        () => ShimArgs.parse([..._baseArgs(), 'extra']),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires --input', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--input'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires --output', () {
      expect(
        () => ShimArgs.parse(_baseArgs(removed: ['--output'])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('runShimWithArgs', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('a no-op Builder writes an empty output file', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(inputPath: input.path, inputAssetPath: "lib/src.dart", outputPath: output.path),
        (_) => _NoopBuilder(),
      );

      expect(output.existsSync(), isTrue);
      expect(output.readAsStringSync(), isEmpty);
    });

    test('a fixed-output Builder writes its emitted contents', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(inputPath: input.path, inputAssetPath: "lib/src.dart", outputPath: output.path),
        (_) => _FixedOutputBuilder('// emitted by fixed builder\n'),
      );

      expect(output.readAsStringSync(), '// emitted by fixed builder\n');
    });

    test('a throwing Builder propagates the error', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(inputPath: input.path, inputAssetPath: "lib/src.dart", outputPath: output.path),
          (_) => _ThrowingBuilder(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('reader exposes declared deps to the Builder', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final dep = File(p.join(tmp.path, 'sibling.dart'))
        ..writeAsStringSync('class Bar {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      String? siblingContent;
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: dep.path, asset: 'lib/sibling.dart')],
        ),
        (_) => _CapturingBuilder((step) async {
          final id = AssetId('fixture', 'lib/sibling.dart');
          siblingContent = await step.readAsString(id);
        }),
      );

      expect(siblingContent, 'class Bar {}');
    });

    test('routes each emitted asset to the matching declared output', () async {
      // Mirrors injectable_config_builder shape: one input → two outputs
      // (.config.dart + .module.dart). Each declared Bazel output must end
      // up with the bytes of the matching emission.
      final input = File(p.join(tmp.path, 'app.dart'))
        ..writeAsStringSync('class App {}');
      final configOut = File(p.join(tmp.path, 'app.config.dart'));
      final moduleOut = File(p.join(tmp.path, 'app.module.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/app.dart',
          outputPath: configOut.path,
          outputPaths: [configOut.path, moduleOut.path],
        ),
        (_) => _MultiOutputBuilder({
          '.config.dart': '// config body\n',
          '.module.dart': '// module body\n',
        }),
      );

      expect(configOut.readAsStringSync(), '// config body\n');
      expect(moduleOut.readAsStringSync(), '// module body\n');
    });

    test('declared output with no matching emission writes empty bytes',
        () async {
      final input = File(p.join(tmp.path, 'app.dart'))
        ..writeAsStringSync('class App {}');
      final configOut = File(p.join(tmp.path, 'app.config.dart'));
      final moduleOut = File(p.join(tmp.path, 'app.module.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/app.dart',
          outputPath: configOut.path,
          outputPaths: [configOut.path, moduleOut.path],
        ),
        (_) => _MultiOutputBuilder({'.config.dart': '// only config\n'}),
      );

      expect(configOut.readAsStringSync(), '// only config\n');
      expect(moduleOut.existsSync(), isTrue);
      expect(moduleOut.readAsStringSync(), isEmpty);
    });

    test('reader rejects undeclared assets', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Object? caught;
      await runShimWithArgs(
        _shimArgs(inputPath: input.path, inputAssetPath: "lib/src.dart", outputPath: output.path),
        (_) => _CapturingBuilder((step) async {
          try {
            await step.readAsString(AssetId('fixture', 'lib/missing.dart'));
          } catch (e) {
            caught = e;
          }
        }),
      );

      expect(caught, isA<AssetNotFoundException>());
    });
  });

  group('Resolver.libraries', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_resolver_libs_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('yields same-package staged libraries (input + each --dep)',
        () async {
      // Baseline: the input file and every --dep file in the same package
      // must appear in Resolver.libraries. Guards the pre-fix behavior.
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final dep = File(p.join(tmp.path, 'sibling.dart'))
        ..writeAsStringSync('class Bar {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Set<String> uris = {};
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: dep.path, asset: 'lib/sibling.dart')],
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uris = libs.map(_libUriString).toSet();
        }),
      );

      // Same-package staged files exist as `package:fixture/...` URIs in
      // the synthetic root; just assert at least one is yielded — the
      // analyzer may canonicalise either input.dart or sibling.dart first.
      expect(
        uris.any((u) => u.startsWith('package:fixture/')),
        isTrue,
        reason: 'expected at least one package:fixture/ library, got $uris',
      );
    });

    test('yields cross-package public re-export libraries from PackageConfig',
        () async {
      // The fix under test: a third-party package whose conventional main
      // library exists (`package:<name>/<name>.dart`) is yielded even
      // though it never appears in _assetIdToPath. Pre-fix, only same-
      // package staged libraries were yielded and generators like
      // stacked_generator's ImportResolver missed reachable types.
      final fooPkg = _writeForeignPackage(root: tmp, name: 'foo');
      final pkgConfig = _writePackageConfig(root: tmp, packages: [fooPkg]);

      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync(
          "import 'package:foo/foo.dart';\nclass Bar extends Foo {}\n",
        );
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Set<String> uris = {};
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          packageConfigPath: pkgConfig,
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uris = libs.map(_libUriString).toSet();
        }),
      );

      expect(
        uris,
        contains('package:foo/foo.dart'),
        reason: 'expected package:foo/foo.dart to be yielded, got $uris',
      );
    });

    test('does not double-yield a library covered by both paths', () async {
      // If a library is reachable both via `_assetIdToPath` and via the
      // PackageConfig fallback, it should be yielded once. Guards against
      // the analyzer caller observing duplicate elements.
      final fooPkg = _writeForeignPackage(root: tmp, name: 'foo');
      final pkgConfig = _writePackageConfig(root: tmp, packages: [fooPkg]);

      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync("import 'package:foo/foo.dart';\nclass Bar {}\n");
      final output = File(p.join(tmp.path, 'src.g.dart'));

      List<String> uriList = [];
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          packageConfigPath: pkgConfig,
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uriList = libs.map(_libUriString).toList();
        }),
      );

      // Set length == list length means no duplicates.
      expect(uriList.length, equals(uriList.toSet().length),
          reason: 'duplicate URIs in libraries: $uriList');
    });

    test('tolerates packages with no conventional main library', () async {
      // Packages may lack `lib/<name>.dart` (CLI tools shipping `bin/`
      // only, packages with non-standard layouts). The new loop must
      // skip them — not throw — so iteration continues to packages that
      // do have one.
      //
      // Set up a package_config with a package whose root directory
      // exists but has no `lib/<name>.dart` file. Draining `libraries`
      // must complete without an exception.
      final emptyPkgDir = Directory(p.join(tmp.path, 'empty_pkg'))
        ..createSync(recursive: true);
      Directory(p.join(emptyPkgDir.path, 'lib')).createSync(recursive: true);
      final pkgConfig = _writePackageConfig(root: tmp, packages: [emptyPkgDir]);

      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          packageConfigPath: pkgConfig,
        ),
        (_) => _CapturingBuilder((step) async {
          // Just drain the stream — assert no exception escapes.
          await step.resolver.libraries.toList();
        }),
      );

      expect(output.existsSync(), isTrue);
    });
  });

  group('runShim diagnostic sink', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_sink_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('argv parse failure routes to sink, not stderr', () async {
      final captured = <String>[];
      await runShim(
        const [],
        (_) => _NoopBuilder(),
        writeDiagnostic: captured.add,
      );
      expect(exitCode, 2);
      expect(captured, isNotEmpty);
      expect(captured.join('\n'), contains('--input'));
      exitCode = 0;
    });

    test('builder throw routes message + stack trace to sink', () async {
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      final captured = <String>[];
      await runShim(
        [
          '--input', input.path,
          '--input-asset', 'lib/a.dart',
          '--output', out,
          '--package', 'p',
          '--root-language-version', '3.11',
        ],
        (_) => _ThrowingBuilder(),
        stagingRoot: stage,
        writeDiagnostic: captured.add,
      );
      expect(exitCode, 1);
      final combined = captured.join('\n');
      expect(combined, contains('Builder failed for'));
      expect(combined, contains('intentional failure'));
      exitCode = 0;
    });

    test('--config JSON is surfaced to the Builder via BuilderOptions', () async {
      // Guards ShimArgs.parse's JSON-object validation + the
      // builder-factory's BuilderOptions wiring. A regression anywhere
      // along `--config '{...}'` → `ShimArgs.config` → `BuilderOptions(config)`
      // would land a different structure at the Builder.
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'a.g.dart'));
      const configJson = '{"foo":"bar","nested":{"k":1}}';
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/a.dart',
          outputPath: output.path,
          config: jsonDecode(configJson) as Map<String, dynamic>,
        ),
        (options) => _ConfigEchoBuilder(options),
      );
      final got = jsonDecode(output.readAsStringSync()) as Map<String, dynamic>;
      expect(got['foo'], 'bar');
      expect(got['nested'], {'k': 1});
    });

    test('multi-dot buildExtensions suffix is correctly routed to output',
        () async {
      // Complements dart_sqlcodegen's dotfile-stem fail-loud (write side)
      // with the read-side equivalent: an output whose builder-declared
      // suffix contains multiple dots (`.foo.bar.baz`) must route
      // correctly through the shim's extension-match logic.
      final input = File(p.join(tmp.path, 'x.dart'))
        ..writeAsStringSync('class X {}');
      final output = File(p.join(tmp.path, 'x.foo.bar.baz'));
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/x.dart',
          outputPath: output.path,
        ),
        (_) => _MultiDotExtensionBuilder(),
      );
      expect(output.existsSync(), isTrue);
      expect(output.readAsStringSync(), '// multi-dot payload\n');
    });

    test('builder log.warning / log.severe reach the diagnostic sink',
        () async {
      // Regression guard for `gotcha_build_log_zone_value.md`. Without
      // the `#buildLog` Zone wiring, `package:build`'s top-level `log`
      // sinks into a silent fallback Logger and warnings from shimmed
      // Builders vanish.
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      final captured = <String>[];
      await runShim(
        [
          '--input', input.path,
          '--input-asset', 'lib/a.dart',
          '--output', out,
          '--package', 'p',
          '--root-language-version', '3.11',
        ],
        (_) => _LoggingBuilder(),
        stagingRoot: stage,
        writeDiagnostic: captured.add,
      );
      final combined = captured.join('\n');
      expect(combined, contains('[WARNING]'));
      expect(combined, contains('builder-emitted warning'));
      expect(combined, contains('[SEVERE]'));
      expect(combined, contains('builder-emitted severe'));
      // exitCode may have been bumped by the SEVERE record; reset.
      exitCode = 0;
    });
  });

  group('expandFlagFiles', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('flagfile_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('non-flagfile args pass through unchanged', () {
      expect(expandFlagFiles(const ['--foo', 'bar', '--baz']),
          ['--foo', 'bar', '--baz']);
    });

    test('@<path> expands one-arg-per-line', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n--output\nsrc.g.dart\n');
      final expanded = expandFlagFiles(['@${ff.path}']);
      expect(expanded, ['--input', 'src.dart', '--output', 'src.g.dart']);
    });

    test('--flagfile= form matches @ form', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n');
      expect(expandFlagFiles(['--flagfile=${ff.path}']),
          ['--input', 'src.dart']);
    });

    test('strips trailing \\r so CRLF flagfiles do not corrupt tokens', () {
      // Regression guard: a trailing \r would make ArgParser.parse reject
      // `--input\r` as an unknown flag.
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\r\nsrc.dart\r\n');
      final expanded = expandFlagFiles(['@${ff.path}']);
      expect(expanded, ['--input', 'src.dart']);
      for (final t in expanded) {
        expect(t, isNot(endsWith('\r')));
      }
    });

    test('empty lines are dropped', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\n\nsrc.dart\n\n');
      expect(expandFlagFiles(['@${ff.path}']), ['--input', 'src.dart']);
    });

    test('mixes flagfile expansion with inline args, preserving order', () {
      final ff = File(p.join(tmp.path, 'args'))
        ..writeAsStringSync('--input\nsrc.dart\n');
      expect(expandFlagFiles(['--before', '@${ff.path}', '--after']),
          ['--before', '--input', 'src.dart', '--after']);
    });
  });

  group('factoryOrFactories normalisation', () {
    // _normaliseFactories is exercised via the public runShimWithArgs
    // surface — passing a bad type must surface ArgumentError rather than
    // silently no-op'ing (silent no-op would mean Bazel sees an empty
    // output file and treats the action as successful).
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('norm_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a non-factory, non-list object throws ArgumentError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));
      await expectLater(
        runShimWithArgs(
          _shimArgs(
              inputPath: input.path,
              inputAssetPath: 'lib/src.dart',
              outputPath: output.path),
          'not a factory',
        ),
        throwsArgumentError,
      );
    });

    test('a List<BuilderFactory> runs each factory against the same BuildStep',
        () async {
      // drift's shim_drift passes [discover, analyzer, driftBuilder]; each
      // factory produces a distinct output extension, and the combining
      // output routing downstream relies on every declared ext being
      // emitted by *some* factory in the list.
      final input = File(p.join(tmp.path, 'app.dart'))
        ..writeAsStringSync('class App {}');
      final firstOut = File(p.join(tmp.path, 'app.first.g.dart'));
      final secondOut = File(p.join(tmp.path, 'app.second.g.dart'));

      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/app.dart',
          outputPath: firstOut.path,
          outputPaths: [firstOut.path, secondOut.path],
        ),
        [
          (_) => _FixedExtensionBuilder('.first.g.dart', '// first\n'),
          (_) => _FixedExtensionBuilder('.second.g.dart', '// second\n'),
        ],
      );

      expect(firstOut.readAsStringSync(), '// first\n');
      expect(secondOut.readAsStringSync(), '// second\n');
    });
  });

  group('emptyOutput hook', () {
    // Regression guard for injectable/shim_metadata.dart: when a source
    // carries no annotations the Builder emits nothing, but stage-2
    // config still needs valid JSON in the declared output — the hook
    // supplies `[]` so jsonDecode downstream sees an empty array.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('empty_output_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('hook fills declared outputs the Builder left unemitted', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path),
        (_) => _NoopBuilder(),
        emptyOutput: (inputId, ext) => utf8.encode('[]'),
      );

      expect(output.readAsStringSync(), '[]');
    });

    test('default (no hook) writes empty bytes', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path),
        (_) => _NoopBuilder(),
      );

      expect(output.readAsStringSync(), isEmpty);
    });
  });

  group('fetchResource across pipeline stages', () {
    // build_runner shares one ResourceManager per build session, so a
    // Resource fetched by stage 1 and stage 2 of the same pipeline is the
    // same instance (drift's shared analysis state relies on this). The
    // shim mirrors that: one manager per runShim invocation, disposed once
    // after the whole pipeline.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_resource_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('stages observe the same Resource instance and state', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resource = Resource<List<String>>(() => <String>[]);
      List<String>? stage1Instance;
      List<String>? stage2Instance;

      await runShimWithArgs(
        _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path),
        [
          (_) => _CapturingBuilder((step) async {
                stage1Instance = await step.fetchResource(resource);
                stage1Instance!.add('stage1');
              }),
          (_) => _CapturingBuilder((step) async {
                stage2Instance = await step.fetchResource(resource);
              }),
        ],
      );

      expect(identical(stage1Instance, stage2Instance), isTrue,
          reason: 'both stages must fetch the same Resource instance');
      expect(stage2Instance, ['stage1']);
    });

    test('Resource dispose runs exactly once after the pipeline', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      var disposeCount = 0;
      final resource = Resource<Object>(
        () => Object(),
        dispose: (_) {
          disposeCount++;
        },
      );

      await runShimWithArgs(
        _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path),
        [
          (_) => _CapturingBuilder((step) async {
                await step.fetchResource(resource);
              }),
          (_) => _CapturingBuilder((step) async {
                await step.fetchResource(resource);
              }),
        ],
      );

      expect(disposeCount, 1,
          reason: 'one shared manager disposes the Resource once');
    });
  });

  group('intermediate-stage buildExtensions validation', () {
    // `_expectedOutputsFor` derives intermediate AssetIds by suffix
    // replacement. An empty-string key (PackageBuilder pattern) makes
    // `endsWith('')` always true and a `$lib$`/`$package$` placeholder key
    // never matches a real path suffix — both silently corrupt the derived
    // AssetId. The shim must reject them loudly for non-final stages.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('build_ext_keys_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('empty-string key in a non-final stage throws StateError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
              inputPath: input.path,
              inputAssetPath: 'lib/src.dart',
              outputPath: output.path),
          [
            (_) => _ExtensionMapBuilder(const {
                  '': ['.meta'],
                }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('unsupported for intermediate pipeline stages'),
        )),
      );
    });

    test(r'$-placeholder key in a non-final stage throws StateError',
        () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
              inputPath: input.path,
              inputAssetPath: 'lib/src.dart',
              outputPath: output.path),
          [
            (_) => _ExtensionMapBuilder(const {
                  r'$lib$': ['lib/gen.dart'],
                }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('unsupported for intermediate pipeline stages'),
        )),
      );
    });

    test('empty-string key is fine when the builder is the final/only stage',
        () async {
      // Final-stage allowedOutputs come from the rule-declared --output
      // paths, so the buildExtensions map is never consulted for AssetId
      // derivation and the PackageBuilder pattern works.
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await runShimWithArgs(
        _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path),
        (_) => _ExtensionMapBuilder(
          const {
            '': ['.meta'],
          },
          write: (step) async {
            await step.writeAsString(
                step.inputId.changeExtension('.g.dart'), '// final stage\n');
          },
        ),
      );

      expect(output.readAsStringSync(), '// final stage\n');
    });
  });

  group('ShimWorkerLoop.performRequest', () {
    // Covers the production hot path (Bazel's persistent-worker protocol).
    // We call performRequest directly — the AsyncWorkerLoop stdin/stdout
    // framing is bazel_worker's responsibility, not ours.
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('worker_loop_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    WorkRequest requestFor(File input, File output, {String? sandboxDir}) =>
        WorkRequest(
          arguments: [
            '--input', input.path,
            '--input-asset', 'lib/${p.basename(input.path)}',
            '--output', output.path,
            '--package', 'fixture',
            '--root-language-version', '3.11',
          ],
          sandboxDir: sandboxDir,
        );

    test('happy path: exitCode 0, output captured is empty', () async {
      final loop = ShimWorkerLoop(factoryOrFactories: (_) => _NoopBuilder());
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resp = await loop.performRequest(requestFor(input, output));

      expect(resp.exitCode, 0);
      expect(resp.output, isEmpty);
      expect(output.existsSync(), isTrue);
    });

    test('builder throw: exitCode non-zero, stack trace in WorkResponse.output',
        () async {
      final loop =
          ShimWorkerLoop(factoryOrFactories: (_) => _ThrowingBuilder());
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resp = await loop.performRequest(requestFor(input, output));

      expect(resp.exitCode, isNonZero);
      // Builder throw surfaces through runShim's own sink, which here is
      // the loop's stderrBuffer → WorkResponse.output. Matches the
      // worker-protocol contract (clean stdout/stderr; diagnostics go in
      // the response).
      expect(resp.output, contains('intentional failure'));
    });

    test('sandboxDir is honoured when Bazel populates it', () async {
      final sandbox = await Directory.systemTemp.createTemp('wr_sandbox_');
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final loop = ShimWorkerLoop(factoryOrFactories: (_) => _NoopBuilder());
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      final resp = await loop.performRequest(
        requestFor(input, output, sandboxDir: sandbox.path),
      );

      expect(resp.exitCode, 0);
      // The shim chdirs into a staging dir under sandboxDir; when the
      // directory didn't exist we'd expect it to be created.
      expect(sandbox.existsSync(), isTrue);
    });

    test('exitCode is reset between requests — a prior failure does not '
        'taint the next success', () async {
      // Uses a swappable factory: first call throws, second is a no-op.
      var call = 0;
      Builder factory(BuilderOptions _) {
        call++;
        return call == 1 ? _ThrowingBuilder() : _NoopBuilder();
      }

      final loop = ShimWorkerLoop(factoryOrFactories: factory);
      final input1 = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class A {}');
      final output1 = File(p.join(tmp.path, 'a.g.dart'));
      final respFail = await loop.performRequest(requestFor(input1, output1));
      expect(respFail.exitCode, isNonZero);

      final input2 = File(p.join(tmp.path, 'b.dart'))
        ..writeAsStringSync('class B {}');
      final output2 = File(p.join(tmp.path, 'b.g.dart'));
      final respOk = await loop.performRequest(requestFor(input2, output2));
      expect(respOk.exitCode, 0,
          reason: 'second request must not inherit first request\'s exit code');
    });
  });
}

/// A Builder declared to produce `.g.dart` outputs but that emits nothing.
class _NoopBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) async {}
}

class _FixedOutputBuilder implements Builder {
  _FixedOutputBuilder(this._contents);
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, _contents);
  }
}

/// Like `_FixedOutputBuilder` but parameterised by output extension so a
/// multi-factory `runShim` list can fan out to distinct declared outputs.
class _FixedExtensionBuilder implements Builder {
  _FixedExtensionBuilder(this._ext, this._contents);
  final String _ext;
  final String _contents;

  @override
  Map<String, List<String>> get buildExtensions => {
        '.dart': [_ext],
      };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension(_ext);
    await step.writeAsString(outId, _contents);
  }
}

class _ThrowingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) async {
    throw StateError('intentional failure');
  }
}

/// Emits log records via `package:build`'s top-level `log`, which only
/// resolves to a captured Logger when the Builder runs inside the
/// `#buildLog` Zone value wired by the shim. Used to guard against the
/// silent-fallback regression documented in
/// `gotcha_build_log_zone_value.md`.
class _LoggingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) async {
    log.warning('builder-emitted warning');
    log.severe('builder-emitted severe');
  }
}

/// Serialises its own `BuilderOptions.config` as JSON into the declared
/// `.g.dart` output. Used to assert the shim correctly plumbs `--config`
/// → `ShimArgs.config` → `BuilderOptions(config)`.
class _ConfigEchoBuilder implements Builder {
  _ConfigEchoBuilder(this._options);
  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.g.dart');
    await step.writeAsString(outId, jsonEncode(_options.config));
  }
}

/// Declares a multi-dot output suffix. Used to verify the shim's output-
/// routing logic matches `.foo.bar.baz` against the declared Bazel output
/// without fracturing on intermediate dots.
class _MultiDotExtensionBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.foo.bar.baz'],
      };

  @override
  Future<void> build(BuildStep step) async {
    final outId = step.inputId.changeExtension('.foo.bar.baz');
    await step.writeAsString(outId, '// multi-dot payload\n');
  }
}

/// Builder with a caller-supplied `buildExtensions` map and an optional
/// write callback. Used to exercise the shim's validation of unsupported
/// buildExtensions key shapes (empty string, `$lib$`/`$package$`).
class _ExtensionMapBuilder implements Builder {
  _ExtensionMapBuilder(this.buildExtensions, {this.write});

  @override
  final Map<String, List<String>> buildExtensions;
  final Future<void> Function(BuildStep)? write;

  @override
  Future<void> build(BuildStep step) async {
    await write?.call(step);
  }
}

class _CapturingBuilder implements Builder {
  _CapturingBuilder(this._fn);
  final Future<void> Function(BuildStep) _fn;

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dart': ['.g.dart'],
      };

  @override
  Future<void> build(BuildStep step) => _fn(step);
}

/// Builder that emits one asset per entry in [_bodies]; keys are the
/// output extensions (e.g. `.config.dart`), values are the bytes written.
/// Used to exercise the shim's multi-output routing.
class _MultiOutputBuilder implements Builder {
  _MultiOutputBuilder(this._bodies);
  final Map<String, String> _bodies;

  @override
  Map<String, List<String>> get buildExtensions => {
        '.dart': _bodies.keys.toList(growable: false),
      };

  @override
  Future<void> build(BuildStep step) async {
    for (final entry in _bodies.entries) {
      final outId = step.inputId.changeExtension(entry.key);
      await step.writeAsString(outId, entry.value);
    }
  }
}
