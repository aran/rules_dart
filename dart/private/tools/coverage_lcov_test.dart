import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:test/test.dart';

import 'coverage_lcov.dart';

/// Where the collector reports a script, and the tracefile it writes; the
/// collection itself runs under `bazel coverage` in `e2e/examples/tests`.
void main() {
  late Directory runfiles;
  setUp(() => runfiles = Directory.systemTemp.createTempSync('lcov_runfiles'));
  tearDown(() => runfiles.deleteSync(recursive: true));

  /// Puts a source in the runfiles at [runfilesPath].
  void source(String runfilesPath, String content) {
    final file = File('${runfiles.path}/$runfilesPath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// [CoverageSources] over `app/lib/app.dart`, `app/test/app_test.dart` and
  /// a generated `app/lib/gen.dart`, whose sources go in [runfiles] with `source`.
  CoverageSources placed() => CoverageSources(
    instrumented: [
      'app/lib/app.dart',
      'app/test/app_test.dart',
      'bazel-out/k8-fastbuild/bin/app/lib/gen.dart',
    ],
    packages: {
      'app': ['app/lib/'],
    },
    files: {
      'app/lib/app.dart': '_main/app/lib/app.dart',
      'app/test/app_test.dart': '_main/app/test/app_test.dart',
      'bazel-out/k8-fastbuild/bin/app/lib/gen.dart': '_main/app/lib/gen.dart',
    },
    locate: (path) => '${runfiles.path}/$path',
  );

  final sources = CoverageSources(
    instrumented: [
      'app/test/app_test.dart',
      'app/lib/app.dart',
      'bazel-out/darwin_arm64-fastbuild/bin/app/lib/app.g.dart',
      'external/+pub+hub+shapes/lib/shapes.dart',
      'split/second/lib/b.dart',
      '',
    ],
    packages: {
      'app': ['app/lib/'],
      'shapes': ['external/+pub+hub+shapes/lib/'],
      'split': ['split/first/lib/', 'split/second/lib/'],
      'root': ['lib/'],
    },
    files: {
      'app/lib/app.dart': '_main/app/lib/app.dart',
      'app/test/app_test.dart': '_main/app/test/app_test.dart',
    },
    locate: (path) => '${runfiles.path}/$path',
  );

  group('CoverageSources.pathOf', () {
    test('finds a file outside lib/ by its path below the roots', () {
      expect(
        sources.pathOf('org-dartlang-root:///app/test/app_test.dart'),
        'app/test/app_test.dart',
      );
    });

    test('finds a package: library through its package', () {
      expect(sources.pathOf('package:app/app.dart'), 'app/lib/app.dart');
      expect(
        sources.pathOf('package:shapes/shapes.dart'),
        'external/+pub+hub+shapes/lib/shapes.dart',
      );
    });

    test('names a generated file by its path in the output tree', () {
      expect(
        sources.pathOf('package:app/app.g.dart'),
        'bazel-out/darwin_arm64-fastbuild/bin/app/lib/app.g.dart',
      );
    });

    test('finds a package split over directories in the one holding it', () {
      expect(sources.pathOf('package:split/b.dart'), 'split/second/lib/b.dart');
    });

    test('reports nothing for a script Bazel does not instrument', () {
      expect(sources.pathOf('dart:core'), isNull);
      expect(sources.pathOf('package:test/test.dart'), isNull);
      expect(sources.pathOf('package:app/other.dart'), isNull);
      expect(sources.pathOf('package:root/missing.dart'), isNull);
      expect(sources.pathOf('org-dartlang-root:///app/x.main.dart'), isNull);
    });
  });

  test('lcov writes each placed file once, its hits merged', () {
    source('_main/app/lib/app.dart', '\n\n\n\n\n');
    source('_main/app/test/app_test.dart', '\n\n');
    final report = lcov({
      'package:app/app.dart': HitMap({3: 1, 1: 0}),
      // The same file under the URI a part or a mixin reports it by.
      'org-dartlang-root:///app/lib/app.dart': HitMap({3: 2, 5: 0}),
      'package:test/test.dart': HitMap({1: 9}),
      'org-dartlang-root:///app/test/app_test.dart': HitMap({2: 1}),
    }, sources);
    expect(
      report,
      'SF:app/lib/app.dart\n'
      'DA:1,0\n'
      'DA:3,3\n'
      'DA:5,0\n'
      'LH:1\n'
      'LF:3\n'
      'end_of_record\n'
      'SF:app/test/app_test.dart\n'
      'DA:2,1\n'
      'LH:1\n'
      'LF:1\n'
      'end_of_record\n',
    );
  });

  group('lcov leaves out what the source ignores', () {
    String report(Map<String, HitMap> hits) => lcov(hits, placed());

    test('a line marked coverage:ignore-line', () {
      source(
        '_main/app/lib/app.dart',
        'int a() => 1;\n'
            'int b() => 2; // coverage:ignore-line\n'
            'int c() => 3;\n',
      );
      expect(
        report({
          'package:app/app.dart': HitMap({1: 1, 2: 0, 3: 4}),
        }),
        'SF:app/lib/app.dart\n'
        'DA:1,1\n'
        'DA:3,4\n'
        'LH:2\n'
        'LF:2\n'
        'end_of_record\n',
      );
    });

    test('the lines from coverage:ignore-start to coverage:ignore-end', () {
      source(
        '_main/app/lib/app.dart',
        'int a() => 1;\n'
            '// coverage:ignore-start\n'
            'int b() => 2;\n'
            'int c() => 3;\n'
            '// coverage:ignore-end\n'
            'int d() => 4;\n',
      );
      expect(
        report({
          'package:app/app.dart': HitMap({1: 1, 2: 0, 3: 1, 4: 0, 5: 0, 6: 2}),
        }),
        'SF:app/lib/app.dart\n'
        'DA:1,1\n'
        'DA:6,2\n'
        'LH:2\n'
        'LF:2\n'
        'end_of_record\n',
      );
    });

    test('a file marked coverage:ignore-file', () {
      source(
        '_main/app/lib/app.dart',
        '// coverage:ignore-file\nint a() => 1;\n',
      );
      source('_main/app/test/app_test.dart', 'void main() {}\n');
      expect(
        report({
          'package:app/app.dart': HitMap({2: 1}),
          'org-dartlang-root:///app/test/app_test.dart': HitMap({1: 1}),
        }),
        'SF:app/test/app_test.dart\n'
        'DA:1,1\n'
        'LH:1\n'
        'LF:1\n'
        'end_of_record\n',
      );
    });

    test('a generated file by its source in the runfiles', () {
      source(
        '_main/app/lib/gen.dart',
        'int a() => 1;\nint b() => 2; // coverage:ignore-line\n',
      );
      expect(
        report({
          'package:app/gen.dart': HitMap({1: 1, 2: 1}),
        }),
        'SF:bazel-out/k8-fastbuild/bin/app/lib/gen.dart\n'
        'DA:1,1\n'
        'LH:1\n'
        'LF:1\n'
        'end_of_record\n',
      );
    });

    test('nothing for a script that is not reported', () {
      // `package:test` has no source in the runfiles, and needs none.
      expect(
        report({
          'package:test/test.dart': HitMap({1: 1}),
          'dart:core': HitMap({1: 1}),
        }),
        isEmpty,
      );
    });

    test('an error for a source missing from the runfiles', () {
      expect(
        () => report({
          'package:app/app.dart': HitMap({1: 1}),
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('app/lib/app.dart is not in the runfiles'),
          ),
        ),
      );
    });

    test('an error for an instrumented file the test does not carry', () {
      final uncarried = CoverageSources(
        instrumented: ['app/lib/app.dart'],
        packages: {
          'app': ['app/lib/'],
        },
        files: {},
        locate: (path) => path,
      );
      expect(
        () => lcov({
          'package:app/app.dart': HitMap({1: 1}),
        }, uncarried),
        throwsA(isA<StateError>()),
      );
    });

    test('an error for a coverage:ignore-start never ended', () {
      source(
        '_main/app/lib/app.dart',
        '// coverage:ignore-start\nint a() => 1;\n',
      );
      expect(
        () => report({
          'package:app/app.dart': HitMap({2: 1}),
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
