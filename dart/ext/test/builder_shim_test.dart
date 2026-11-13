import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
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
  return [
    for (final e in args.entries) ...[e.key, e.value],
  ];
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
}) => ShimArgs(
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
    // Strip the trailing marker only — `replaceAll` would also eat it out of
    // the middle of a package name that happens to contain `_pkg`.
    final dirName = p.basename(pkg.path);
    final name = dirName.endsWith('_pkg')
        ? dirName.substring(0, dirName.length - '_pkg'.length)
        : dirName;
    entries.add({
      'name': name,
      'rootUri': Uri.directory(pkg.path).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
  }
  final file = File(p.join(root.path, 'package_config.json'));
  file.writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': entries}));
  return file.path;
}

void main() {
  // The package a generator sees is exactly the one its target declares: the
  // declared files, the user's own pubspec and analysis options, and nothing
  // else. Output must not depend on where the action ran.
  group('what a generator sees', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_sees_');
    });

    tearDown(() async {
      // Staged copies of Bazel outputs are read-only; make them deletable.
      await Process.run('chmod', ['-R', 'u+rwX', tmp.path]);
      await tmp.delete(recursive: true);
    });

    Future<String?> readStaged(
      String asset, {
      required String content,
      bool readOnly = false,
    }) async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final declared = File(p.join(tmp.path, 'declared_${asset.hashCode}'))
        ..writeAsStringSync(content);
      if (readOnly) await Process.run('chmod', ['0444', declared.path]);
      String? seen;
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: p.join(tmp.path, 'src.g.dart'),
          depPaths: [(exec: declared.path, asset: asset)],
        ),
        (_) => _CapturingBuilder((step) async {
          seen = await step.readAsString(AssetId('fixture', asset));
        }),
      );
      return seen;
    }

    for (final asset in ['pubspec.yaml', 'analysis_options.yaml']) {
      for (final readOnly in [false, true]) {
        test(
          'the $asset the target passes is the one the generator reads'
          '${readOnly ? ' (read-only, as a Bazel output is)' : ''}',
          () async {
            final mine =
                '# mine\nname: fixture\nversion: 9.9.9\n'
                'environment:\n  sdk: ^3.11.0\n';
            expect(
              await readStaged(asset, content: mine, readOnly: readOnly),
              mine,
              reason: 'the shim must not replace a file the user declared',
            );
          },
        );
      }
    }

    for (final (what, content, says) in [
      (
        'name',
        'name: other\nenvironment:\n  sdk: ^3.11.0\n',
        '`name: other`, but the target\'s `package_name` is "fixture"',
      ),
      (
        'language version',
        'name: fixture\nenvironment:\n  sdk: ">=3.9.0 <4.0.0"\n',
        'which is language version 3.9, but the target\'s language version '
            'is 3.11',
      ),
      (
        'missing SDK constraint',
        'name: fixture\n',
        'no `environment.sdk`, which is language version 2.7',
      ),
    ]) {
      test('a pubspec whose $what disagrees with the target fails', () async {
        await expectLater(
          readStaged('pubspec.yaml', content: content),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('disagrees with the target'), contains(says)),
            ),
          ),
        );
      });
    }

    test('a read-only declared input does not fail the action', () async {
      expect(
        await readStaged('lib/ro.dart', content: 'class R {}', readOnly: true),
        'class R {}',
      );
    });

    /// Runs a builder over [asset] staged under [root] and returns what it
    /// saw of the input library's identity.
    Future<Map<String, String>> identityUnder(
      Directory root,
      String asset,
    ) async {
      final input = File(p.join(tmp.path, 'main_src.dart'))
        ..writeAsStringSync('class Main {}');
      final seen = <String, String>{};
      final diagnostics = <String>[];
      exitCode = 0;
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          asset,
          '--output',
          p.join(tmp.path, 'out_${root.path.hashCode}.g.dart'),
          '--package',
          'fixture',
          '--root-language-version',
          '3.11',
        ],
        (_) => _CapturingBuilder((step) async {
          final lib = await step.resolver.libraryFor(step.inputId);
          seen['uri'] = lib.firstFragment.source.uri.toString();
          seen['libraries'] = (await step.resolver.libraries.toList())
              .map(_libUriString)
              .where((u) => u.contains('main') || u.contains('shim_'))
              .join(',');
        }),
        stagingRoot: root,
        writeDiagnostic: diagnostics.add,
      );
      expect(exitCode, 0, reason: diagnostics.join('\n'));
      exitCode = 0;
      return seen;
    }

    for (final asset in ['lib/main.dart']) {
      test('$asset has the same identity wherever the action runs and '
          'names no temp path', () async {
        final a = await Directory(p.join(tmp.path, 'tmp_a')).create();
        final b = await Directory(p.join(tmp.path, 'tmp_b_longer')).create();
        final underA = await identityUnder(a, asset);
        final underB = await identityUnder(b, asset);
        expect(underA, underB, reason: 'output must not depend on TMPDIR');
        for (final value in underA.values) {
          expect(value, isNot(contains('shim_')));
          expect(value, isNot(contains(tmp.path)));
        }
        expect(underA['uri'], isNot(startsWith('file:')));
      });
    }

    // Bazel's worker contract: a worker reads only WorkRequest.inputs. The
    // package config's rootUri points at the real package, so everything
    // else under it is also readable unless the shim stops it.
    group('in a worker', () {
      late Directory pkgRoot;
      late String pkgConfig;
      late File input;

      setUp(() async {
        final foo = _writeForeignPackage(root: tmp, name: 'foo');
        File(
          p.join(foo.path, 'lib', 'declared.txt'),
        ).writeAsStringSync('declared');
        File(
          p.join(foo.path, 'lib', 'undeclared.txt'),
        ).writeAsStringSync('SECRET');
        File(
          p.join(foo.path, 'lib', 'undeclared.dart'),
        ).writeAsStringSync('class Hidden {}');
        pkgRoot = foo;
        pkgConfig = _writePackageConfig(root: tmp, packages: [foo]);
        input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync("import 'package:foo/foo.dart';\nclass B {}\n");
      });

      // The request runs in an isolate of its own, so what the builder saw
      // comes back as the last line it prints, which lands in the output.
      Future<Map<String, Object?>> run(
        Set<String> declared,
        Future<void> Function(BuildStep, Map<String, Object?>) body,
      ) async {
        final loop = ShimWorkerLoop(
          factoryOrFactories: (_) => _CapturingBuilder((s) async {
            final seen = <String, Object?>{};
            await body(s, seen);
            // The worker captures a builder's `print` into the response output.
            // ignore: avoid_print
            print(jsonEncode(seen));
          }),
        );
        final resp = await loop.performRequest(
          WorkRequest(
            arguments: [
              '--input',
              input.path,
              '--input-asset',
              'lib/src.dart',
              '--output',
              p.join(tmp.path, 'src.g.dart'),
              '--package',
              'fixture',
              '--root-language-version',
              '3.11',
              '--package-config',
              pkgConfig,
            ],
            inputs: [
              Input(path: input.path),
              Input(path: pkgConfig),
              for (final f in declared) Input(path: p.join(pkgRoot.path, f)),
            ],
          ),
        );
        expect(resp.exitCode, 0, reason: resp.output);
        return jsonDecode(const LineSplitter().convert(resp.output).last)
            as Map<String, Object?>;
      }

      Future<Object?> tryRead(BuildStep s, String path) async {
        try {
          return await s.readAsString(AssetId('foo', path));
        } on AssetNotFoundException {
          return 'AssetNotFoundException';
        }
      }

      test('a declared dependency file is readable (control)', () async {
        final seen = await run({'lib/foo.dart', 'lib/declared.txt'}, (
          s,
          m,
        ) async {
          m['declared'] = await tryRead(s, 'lib/declared.txt');
        });
        expect(seen['declared'], 'declared');
      });

      test(
        'an undeclared non-Dart file of a dependency is not readable',
        () async {
          final seen = await run({'lib/foo.dart'}, (s, m) async {
            m['secret'] = await tryRead(s, 'lib/undeclared.txt');
          });
          expect(
            seen['secret'],
            'AssetNotFoundException',
            reason: 'output would depend on a file no dependency declared',
          );
        },
      );

      test(
        'an undeclared Dart file of a dependency is not resolvable',
        () async {
          final seen = await run({'lib/foo.dart'}, (s, m) async {
            final id = AssetId('foo', 'lib/undeclared.dart');
            m['canRead'] = await s.canRead(id);
            m['isLibrary'] = await s.resolver.isLibrary(id);
          });
          expect(seen['canRead'], isFalse);
          expect(seen['isLibrary'], isFalse);
        },
      );
    });
  });

  group('stagedPath', () {
    test(
      'joins a POSIX asset under a native Windows dir, no mixed separators',
      () {
        final dest = stagedPath(
          p.windows,
          r'C:\tmp\shim_x',
          'test/nice_mock_test.dart',
        );
        expect(dest, r'C:\tmp\shim_x\test\nice_mock_test.dart');
        expect(dest, isNot(contains('/')));
      },
    );

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

  group('the SDK from a summary', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_sdk_summary_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('resolves the SDK from the summary the shim wrote', () async {
      final summary = p.join(tmp.path, 'sdk.sum');
      await writeSdkSummary([
        '--sdk',
        p.dirname(p.dirname(Platform.resolvedExecutable)),
        '--out',
        summary,
      ]);
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync(
          'abstract class Foo extends Iterable<Future<int>> {}',
        );
      final out = p.join(tmp.path, 'a.g.dart');
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      final captured = <String>[];
      await runShim(
        [
          ..._baseArgs(removed: ['--input', '--output']),
          '--input',
          input.path,
          '--output',
          out,
          '--sdk-summary',
          summary,
        ],
        (_) => _SupertypeBuilder(),
        stagingRoot: stage,
        writeDiagnostic: captured.add,
      );
      expect(exitCode, 0, reason: captured.join('\n'));
      expect(File(out).readAsStringSync(), 'Iterable<Future<int>>');
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
        '--output',
        'a.config.dart',
        '--output',
        'a.module.dart',
      ]);
      expect(args.outputPaths, ['a.config.dart', 'a.module.dart']);
    });

    test('--sdk-path and --sdk-summary are exclusive', () {
      expect(
        () => ShimArgs.parse([
          ..._baseArgs(),
          '--sdk-path',
          'sdk',
          '--sdk-summary',
          'sdk.sum',
        ]),
        throwsA(isA<FormatException>()),
      );
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
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': 'not-a-version'}),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': '3'}),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--root-language-version': 'abc.def'}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('--config rejects non-object JSON', () {
      expect(
        () => ShimArgs.parse(
          _baseArgs(overrides: {'--config': '"a string is not an object"'}),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('JSON object'),
          ),
        ),
      );
    });

    test('--config rejects malformed JSON', () {
      expect(
        () => ShimArgs.parse(_baseArgs(overrides: {'--config': '{not valid'})),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Parse error'),
          ),
        ),
      );
    });

    test('parses --config JSON object', () {
      final args = ShimArgs.parse(
        _baseArgs(overrides: {'--config': '{"createFactory": false}'}),
      );
      expect(args.config, {'createFactory': false});
    });

    test('parses repeatable --dep (exec|asset form)', () {
      final args = ShimArgs.parse([
        ..._baseArgs(),
        '--dep',
        'exec/sibling1.dart|lib/sibling1.dart',
        '--dep',
        'exec/sibling2.dart|lib/src/sibling2.dart',
      ]);
      expect(args.depPaths.map((d) => d.exec), [
        'exec/sibling1.dart',
        'exec/sibling2.dart',
      ]);
      expect(args.depPaths.map((d) => d.asset), [
        'lib/sibling1.dart',
        'lib/src/sibling2.dart',
      ]);
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
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
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
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
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
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: "lib/src.dart",
            outputPath: output.path,
          ),
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
      // Mirrors a multi-output builder shape: one input → two outputs
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

    test(
      'declared output with no matching emission writes empty bytes',
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
      },
    );

    test('reader rejects undeclared assets', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Object? caught;
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: "lib/src.dart",
          outputPath: output.path,
        ),
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

    test('yields same-package staged libraries (input + each --dep)', () async {
      // Baseline: the input file and every --dep file in the same package
      // must appear in Resolver.libraries.
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

      // Both staged files, by name. `any(startsWith('package:fixture/'))`
      // would also be satisfied by the synthetic `package:fixture/fixture.dart`
      // the config loop yields for the root package, so it would pass with the
      // staged loop removed entirely.
      expect(
        uris,
        containsAll(<String>[
          'package:fixture/src.dart',
          'package:fixture/sibling.dart',
        ]),
        reason: 'expected both staged libraries, got $uris',
      );
    });

    test(
      'yields cross-package public re-export libraries from PackageConfig',
      () async {
        // A third-party package whose conventional main library exists
        // (`package:<name>/<name>.dart`) is yielded even though it never
        // appears in _assetIdToPath.
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
      },
    );

    test('skips a staged non-Dart dep, and keeps going', () async {
      // The staged loop has always claimed to skip non-library assets such
      // as plain-text deps, but nothing staged one, so deleting its catch
      // broke no test. Predates the cross-package change; covered here
      // because the same drain now reaches further and an escaping
      // exception would take the whole stream with it.
      //
      // The `.txt` sorts before `src.dart` in the staged map, so an escape
      // aborts the drain before any library is yielded.
      final data = File(p.join(tmp.path, 'data.txt'))
        ..writeAsStringSync('not dart at all\n');
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}\n');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      Set<String> uris = {};
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: data.path, asset: 'lib/data.txt')],
        ),
        (_) => _CapturingBuilder((step) async {
          uris = (await step.resolver.libraries.toList())
              .map(_libUriString)
              .toSet();
        }),
      );

      expect(
        uris,
        contains('package:fixture/src.dart'),
        reason: 'the staged .txt aborted the drain, got $uris',
      );
      expect(uris, isNot(contains('package:fixture/data.txt')));
    });

    test('does not double-yield a library covered by both paths', () async {
      // If a library is reachable both via `_assetIdToPath` and via the
      // PackageConfig fallback, it should be yielded once. Guards against
      // the analyzer caller observing duplicate elements.
      //
      // The collision has to be constructed deliberately. `_buildPackageConfig`
      // puts a synthetic entry for the root package (`fixture`) into the
      // config, so the fallback loop asks for `package:fixture/fixture.dart`.
      // Staging a `--dep` at exactly that asset path is what makes one library
      // reachable both ways; without it the two loops cover disjoint URIs and
      // this test passes whether or not the dedup exists.
      final fooPkg = _writeForeignPackage(root: tmp, name: 'foo');
      final pkgConfig = _writePackageConfig(root: tmp, packages: [fooPkg]);

      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync("import 'package:foo/foo.dart';\nclass Bar {}\n");
      final collide = File(p.join(tmp.path, 'fixture.dart'))
        ..writeAsStringSync('class Collide {}\n');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      List<String> uriList = [];
      await runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: output.path,
          depPaths: [(exec: collide.path, asset: 'lib/fixture.dart')],
          packageConfigPath: pkgConfig,
        ),
        (_) => _CapturingBuilder((step) async {
          final libs = await step.resolver.libraries.toList();
          uriList = libs.map(_libUriString).toList();
        }),
      );

      // Assert the collision actually got set up: if this URI stops being
      // reachable both ways, the no-duplicates check below goes vacuous and
      // would keep passing with the dedup deleted.
      expect(
        uriList,
        contains('package:fixture/fixture.dart'),
        reason: 'fixture no longer collides across both paths, got $uriList',
      );

      // Set length == list length means no duplicates.
      expect(
        uriList.length,
        equals(uriList.toSet().length),
        reason: 'duplicate URIs in libraries: $uriList',
      );
    });

    test(
      'skips a package whose main library is a part, and keeps going',
      () async {
        // `libraryFor` throws `NonLibraryAssetException` when the file at the
        // conventional path parses as a `part of` rather than a library. The
        // loop must swallow that and continue, or one oddly-laid-out package
        // truncates the stream for every package after it.
        //
        // Ordering is the whole point: `partpkg` sorts before `zfoo`, so if the
        // catch is removed the exception escapes before `zfoo` is ever reached
        // and the assertion below fails. A fixture with only the bad package
        // would still pass with no catch at all, since nothing would follow it.
        final partPkg = Directory(p.join(tmp.path, 'partpkg_pkg'))
          ..createSync(recursive: true);
        Directory(p.join(partPkg.path, 'lib')).createSync(recursive: true);
        File(
          p.join(partPkg.path, 'lib', 'partpkg.dart'),
        ).writeAsStringSync("part of 'somewhere.dart';\n");
        final zfooPkg = _writeForeignPackage(root: tmp, name: 'zfoo');
        final pkgConfig = _writePackageConfig(
          root: tmp,
          packages: [partPkg, zfooPkg],
        );

        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
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
            uris = (await step.resolver.libraries.toList())
                .map(_libUriString)
                .toSet();
          }),
        );

        expect(
          uris,
          contains('package:zfoo/zfoo.dart'),
          reason: 'iteration stopped at the part-only package, got $uris',
        );
        expect(uris, isNot(contains('package:partpkg/partpkg.dart')));
        expect(output.existsSync(), isTrue);
      },
    );

    test(
      'yields a synthetic empty library for a missing main library',
      () async {
        // A package declared in the config with no `lib/<name>.dart` on disk
        // does NOT throw, and so is not skipped: the analyzer answers
        // `getLibraryByUri` for a nonexistent file with an empty library, and
        // the loop yields it. Recorded because it is the opposite of what the
        // surrounding comments would lead you to expect, and because it is
        // what makes both `catch` arms unreachable for this shape.
        //
        // Harmless in practice — an empty library contributes no elements to a
        // generator walking the stream for types — so this pins the behavior
        // rather than asserting it is the behavior we would have chosen.
        final emptyPkgDir = Directory(p.join(tmp.path, 'empty_pkg'))
          ..createSync(recursive: true);
        Directory(p.join(emptyPkgDir.path, 'lib')).createSync(recursive: true);
        final pkgConfig = _writePackageConfig(
          root: tmp,
          packages: [emptyPkgDir],
        );

        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
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
            uris = (await step.resolver.libraries.toList())
                .map(_libUriString)
                .toSet();
          }),
        );

        expect(uris, contains('package:empty/empty.dart'));
        expect(output.existsSync(), isTrue);
      },
    );
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

    test('staging root bounds analysis-options discovery', () async {
      // The staging dir is created under a temp root, so its ancestors are
      // whatever the machine happens to have there. If the analyzer's walk-up
      // reached them, codegen would be configured by a stray file —
      // differently on different machines.
      //
      // `exclude: '**'` is planted above deliberately: it is the ancestor
      // setting most likely to change generation if it were ever consulted.
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      File(
        p.join(tmp.path, 'analysis_options.yaml'),
      ).writeAsStringSync('analyzer:\n  exclude:\n    - "**"\n');

      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');

      String? optionsFile = 'not checked';
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          'lib/a.dart',
          '--output',
          out,
          '--package',
          'p',
          '--root-language-version',
          '3.11',
        ],
        (_) => _FixedOutputBuilder('// generated'),
        stagingRoot: stage,
        buildAnalysisContext:
            ({
              required List<String> includedPaths,
              required String sdkPath,
              required String? sdkSummaryPath,
              required ResourceProvider resourceProvider,
            }) async {
              final collection = AnalysisContextCollection(
                includedPaths: includedPaths,
                sdkPath: sdkPath,
                resourceProvider: resourceProvider,
              );
              optionsFile =
                  collection.contexts.single.contextRoot.optionsFile?.path;
              return collection;
            },
      );

      expect(
        optionsFile,
        isNull,
        reason: 'the analyzer found an analysis_options.yaml above staging',
      );
      expect(File(out).existsSync(), isTrue);
      expect(File(out).readAsStringSync(), contains('// generated'));
    });

    group('analysis collection dispose failure', () {
      Future<List<String>> run(Builder Function(BuilderOptions) factory) async {
        final input = File(p.join(tmp.path, 'a.dart'))
          ..writeAsStringSync('class Foo {}');
        final out = p.join(tmp.path, 'a.g.dart');
        final stage = await Directory(p.join(tmp.path, 'stage')).create();
        final captured = <String>[];
        await runShim(
          [
            '--input',
            input.path,
            '--input-asset',
            'lib/a.dart',
            '--output',
            out,
            '--package',
            'p',
            '--root-language-version',
            '3.11',
          ],
          factory,
          stagingRoot: stage,
          writeDiagnostic: captured.add,
          buildAnalysisContext:
              ({
                required List<String> includedPaths,
                required String sdkPath,
                required String? sdkSummaryPath,
                required ResourceProvider resourceProvider,
              }) async => _DisposeThrowsCollection(),
        );
        return captured;
      }

      test('fails the action with a clear message', () async {
        final captured = await run((_) => _NoopBuilder());
        expect(exitCode, 1);
        expect(
          captured.join('\n'),
          contains('AnalysisContextCollection.dispose failed'),
        );
        exitCode = 0;
      });

      test('does not mask the builder error', () async {
        final captured = await run((_) => _ThrowingBuilder());
        expect(exitCode, 1);
        final combined = captured.join('\n');
        expect(combined, contains('intentional failure'));
        expect(combined, contains('dispose failed'));
        exitCode = 0;
      });
    });

    test('builder throw routes message + stack trace to sink', () async {
      final input = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class Foo {}');
      final out = p.join(tmp.path, 'a.g.dart');
      final stage = await Directory(p.join(tmp.path, 'stage')).create();
      final captured = <String>[];
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          'lib/a.dart',
          '--output',
          out,
          '--package',
          'p',
          '--root-language-version',
          '3.11',
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
        (BuilderOptions options) => _ConfigEchoBuilder(options),
      );
      final got = jsonDecode(output.readAsStringSync()) as Map<String, dynamic>;
      expect(got['foo'], 'bar');
      expect(got['nested'], {'k': 1});
    });

    test(
      'multi-dot buildExtensions suffix is correctly routed to output',
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
      },
    );

    test(
      'builder log.warning / log.severe reach the diagnostic sink',
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
            '--input',
            input.path,
            '--input-asset',
            'lib/a.dart',
            '--output',
            out,
            '--package',
            'p',
            '--root-language-version',
            '3.11',
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
      },
    );
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
      expect(expandFlagFiles(const ['--foo', 'bar', '--baz']), [
        '--foo',
        'bar',
        '--baz',
      ]);
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
      expect(expandFlagFiles(['--flagfile=${ff.path}']), [
        '--input',
        'src.dart',
      ]);
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
      expect(expandFlagFiles(['--before', '@${ff.path}', '--after']), [
        '--before',
        '--input',
        'src.dart',
        '--after',
      ]);
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
            outputPath: output.path,
          ),
          'not a factory',
        ),
        throwsArgumentError,
      );
    });

    test(
      'a List<BuilderFactory> runs each factory against the same BuildStep',
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
      },
    );
  });

  // A generator that writes the input library's own URI into its output (as
  // stacked's router and locator do) sees a `file:` URI for inputs outside
  // lib/, which names the shim's temporary staging dir. Generated code must
  // not depend on where the action ran: it must compile, and it must be the
  // same bytes on every run so it can be cached.
  group('generated output identity', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_identity_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// Runs [emit] as the builder over [asset] staged under [root], and
    /// returns the generated output, or the diagnostics if the action
    /// failed.
    Future<({String? output, String diagnostics})> generateUnder(
      Directory root,
      String asset,
      String Function(Uri inputUri) emit,
    ) async {
      final input = File(p.join(tmp.path, 'input.dart'))
        ..writeAsStringSync('class Main {}');
      final outDir = await Directory(
        p.join(tmp.path, 'out', p.basename(root.path)),
      ).create(recursive: true);
      final out = File(
        p.join(outDir.path, '${p.basenameWithoutExtension(asset)}.g.dart'),
      );
      final diagnostics = <String>[];
      exitCode = 0;
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          asset,
          '--output',
          out.path,
          '--package',
          'fixture',
          '--root-language-version',
          '3.11',
        ],
        (_) => _CapturingBuilder((step) async {
          final lib = await step.resolver.libraryFor(step.inputId);
          await step.writeAsString(
            step.inputId.changeExtension('.g.dart'),
            emit(lib.firstFragment.source.uri),
          );
        }),
        stagingRoot: root,
        writeDiagnostic: diagnostics.add,
      );
      final failed = exitCode != 0;
      exitCode = 0;
      return (
        output: failed ? null : out.readAsStringSync(),
        diagnostics: diagnostics.join('\n'),
      );
    }

    String directives(Uri uri) =>
        "import '$uri' as _i1;\n"
        "export '$uri' show Main;\n"
        'void f(_i1.Main m) {}\n';

    for (final (asset, relative) in [
      ('lib/main.dart', 'package:fixture/main.dart'),
      ('bin/main.dart', 'main.dart'),
      ('test/main_test.dart', 'main_test.dart'),
      ('test/sub/main_test.dart', 'main_test.dart'),
    ]) {
      test('$asset: output names no temp path and is the same wherever '
          'the action runs', () async {
        final a = await Directory(p.join(tmp.path, 'tmp_a')).create();
        final b = await Directory(p.join(tmp.path, 'tmp_b_longer')).create();
        final underA = await generateUnder(a, asset, directives);
        final underB = await generateUnder(b, asset, directives);
        expect(underA.output, isNotNull, reason: underA.diagnostics);
        expect(underA.output, underB.output, reason: 'depends on TMPDIR');
        expect(underA.output, isNot(contains('shim_')));
        expect(underA.output, isNot(contains(tmp.path)));
        expect(
          underA.output,
          "import '$relative' as _i1;\n"
          "export '$relative' show Main;\n"
          'void f(_i1.Main m) {}\n',
        );
      });
    }

    test('a staging URI to a sibling file becomes a relative path', () async {
      final out = await generateUnder(
        await Directory(p.join(tmp.path, 'stage')).create(),
        'bin/main.dart',
        (uri) =>
            "import '${uri.resolve('sub/views.dart')}';\n"
            "part '${uri.resolve('../lib/part.dart')}';\n",
      );
      expect(out.output, isNotNull, reason: out.diagnostics);
      expect(
        out.output,
        "import 'sub/views.dart';\npart '../lib/part.dart';\n",
      );
    });

    test('the staging path anywhere but a directive URI fails the '
        'action', () async {
      final out = await generateUnder(
        await Directory(p.join(tmp.path, 'stage')).create(),
        'bin/main.dart',
        (uri) => "// generated from $uri\nconst source = '${uri.path}';\n",
      );
      expect(out.output, isNull, reason: 'the action must fail');
      expect(out.diagnostics, contains('temporary staging'));
    });
  });

  group('unemitted outputs', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('empty_output_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'declared outputs the Builder left unemitted are written empty',
      () async {
        final input = File(p.join(tmp.path, 'src.dart'))
          ..writeAsStringSync('class Foo {}');
        final output = File(p.join(tmp.path, 'src.g.dart'));

        await runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          (_) => _NoopBuilder(),
        );

        expect(output.readAsStringSync(), isEmpty);
      },
    );
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
          outputPath: output.path,
        ),
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

      expect(
        identical(stage1Instance, stage2Instance),
        isTrue,
        reason: 'both stages must fetch the same Resource instance',
      );
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
          outputPath: output.path,
        ),
        [
          (_) => _CapturingBuilder((step) async {
            await step.fetchResource(resource);
          }),
          (_) => _CapturingBuilder((step) async {
            await step.fetchResource(resource);
          }),
        ],
      );

      expect(
        disposeCount,
        1,
        reason: 'one shared manager disposes the Resource once',
      );
    });
  });

  group('Resource disposal failure', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_resource_fail_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<void> run(Future<void> Function(BuildStep) body) {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      return runShimWithArgs(
        _shimArgs(
          inputPath: input.path,
          inputAssetPath: 'lib/src.dart',
          outputPath: p.join(tmp.path, 'src.g.dart'),
        ),
        [(_) => _CapturingBuilder(body)],
      );
    }

    final failing = Resource<Object>(
      () => Object(),
      dispose: (_) => throw StateError('resource boom'),
    );

    test('fails the action with the failure message', () async {
      await expectLater(
        run((step) async => step.fetchResource(failing)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('ResourceManager.disposeAll failed'),
          ),
        ),
      );
    });

    test('does not mask a builder error', () async {
      await expectLater(
        run((step) async {
          await step.fetchResource(failing);
          throw StateError('builder boom');
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('builder boom'),
          ),
        ),
      );
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
            outputPath: output.path,
          ),
          [
            (_) => _ExtensionMapBuilder(const {
              '': ['.meta'],
            }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsupported for intermediate pipeline stages'),
          ),
        ),
      );
    });

    test(r'$-placeholder key in a non-final stage throws StateError', () async {
      final input = File(p.join(tmp.path, 'src.dart'))
        ..writeAsStringSync('class Foo {}');
      final output = File(p.join(tmp.path, 'src.g.dart'));

      await expectLater(
        runShimWithArgs(
          _shimArgs(
            inputPath: input.path,
            inputAssetPath: 'lib/src.dart',
            outputPath: output.path,
          ),
          [
            (_) => _ExtensionMapBuilder(const {
              r'$lib$': ['lib/gen.dart'],
            }),
            (_) => _NoopBuilder(),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unsupported for intermediate pipeline stages'),
          ),
        ),
      );
    });

    test(
      'empty-string key is fine when the builder is the final/only stage',
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
            outputPath: output.path,
          ),
          (_) => _ExtensionMapBuilder(
            const {
              '': ['.meta'],
            },
            write: (step) async {
              await step.writeAsString(
                step.inputId.changeExtension('.g.dart'),
                '// final stage\n',
              );
            },
          ),
        );

        expect(output.readAsStringSync(), '// final stage\n');
      },
    );
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
            '--input',
            input.path,
            '--input-asset',
            'lib/${p.basename(input.path)}',
            '--output',
            output.path,
            '--package',
            'fixture',
            '--root-language-version',
            '3.11',
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

    test(
      'builder throw: exitCode non-zero, stack trace in WorkResponse.output',
      () async {
        final loop = ShimWorkerLoop(
          factoryOrFactories: (_) => _ThrowingBuilder(),
        );
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
      },
    );

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
      // The first input asks the builder to throw; the second does not.
      final loop = ShimWorkerLoop(
        factoryOrFactories: (_) => _CapturingBuilder((s) async {
          if ((await s.readAsString(s.inputId)).contains('FAIL')) {
            throw StateError('intentional failure');
          }
        }),
      );
      final input1 = File(p.join(tmp.path, 'a.dart'))
        ..writeAsStringSync('class A {} // FAIL');
      final output1 = File(p.join(tmp.path, 'a.g.dart'));
      final respFail = await loop.performRequest(requestFor(input1, output1));
      expect(respFail.exitCode, isNonZero);

      final input2 = File(p.join(tmp.path, 'b.dart'))
        ..writeAsStringSync('class B {}');
      final output2 = File(p.join(tmp.path, 'b.g.dart'));
      final respOk = await loop.performRequest(requestFor(input2, output2));
      expect(
        respOk.exitCode,
        0,
        reason: 'second request must not inherit first request\'s exit code',
      );
    });

    test('state a generator keeps for one build lasts one request', () async {
      // `json_serializable` checks the pubspec once and remembers it in a
      // top-level variable, as `_warnOnce` does: every request must warn, as
      // every one-shot run does.
      final loop = ShimWorkerLoop(
        factoryOrFactories: (_) => _CapturingBuilder((s) async {
          _warnOnce();
        }),
      );
      for (final name in ['a', 'b']) {
        final input = File(p.join(tmp.path, '$name.dart'))
          ..writeAsStringSync('class X {}');
        final resp = await loop.performRequest(
          requestFor(input, File(p.join(tmp.path, '$name.g.dart'))),
        );
        expect(resp.exitCode, 0, reason: resp.output);
        expect(resp.output, contains('checked once per build'), reason: name);
      }
    });
  });

  // As build_runner's resolver: a library with a syntax error is refused
  // unless the builder allows it, so no generator runs over a parse the
  // analyzer recovered from by guessing.
  group('a source with a syntax error', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shim_syntax_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    Future<({bool ok, String diagnostics})> resolve(
      Future<void> Function(BuildStep step) read,
    ) async {
      final input = File(p.join(tmp.path, 'input.dart'))
        ..writeAsStringSync('class Main {\n  void f( {}\n');
      final root = await Directory(p.join(tmp.path, 'root')).create();
      final diagnostics = <String>[];
      exitCode = 0;
      await runShim(
        [
          '--input',
          input.path,
          '--input-asset',
          'lib/main.dart',
          '--output',
          p.join(tmp.path, 'main.g.dart'),
          '--package',
          'fixture',
          '--root-language-version',
          '3.11',
        ],
        (_) => _CapturingBuilder((step) async {
          await read(step);
          await step.writeAsString(
            step.inputId.changeExtension('.g.dart'),
            '// generated\n',
          );
        }),
        stagingRoot: root,
        writeDiagnostic: diagnostics.add,
      );
      final ok = exitCode == 0;
      exitCode = 0;
      return (ok: ok, diagnostics: diagnostics.join('\n'));
    }

    test('is refused by libraryFor', () async {
      final r = await resolve((step) => step.resolver.libraryFor(step.inputId));
      expect(r.ok, isFalse);
      expect(r.diagnostics, contains('Expected an identifier'));
    });

    test('is refused by compilationUnitFor', () async {
      final r = await resolve(
        (step) => step.resolver.compilationUnitFor(step.inputId),
      );
      expect(r.ok, isFalse);
      expect(r.diagnostics, contains('Expected an identifier'));
    });

    test('is read when the builder allows syntax errors', () async {
      final r = await resolve((step) async {
        await step.resolver.libraryFor(step.inputId, allowSyntaxErrors: true);
        await step.resolver.compilationUnitFor(
          step.inputId,
          allowSyntaxErrors: true,
        );
      });
      expect(r.ok, isTrue, reason: r.diagnostics);
    });
  });
}

/// A Builder declared to produce `.g.dart` outputs but that emits nothing.
class _DisposeThrowsCollection implements AnalysisContextCollection {
  @override
  Future<void> dispose({bool forTesting = false}) async =>
      throw StateError('boom');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {}
}

/// Writes the supertype of the input's first class, which only a resolved
/// SDK names.
class _SupertypeBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final library = await step.inputLibrary;
    await step.writeAsString(
      step.allowedOutputs.single,
      library.classes.first.supertype!.getDisplayString(),
    );
  }
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

var _warned = false;

void _warnOnce() {
  if (_warned) return;
  _warned = true;
  log.warning('checked once per build');
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
