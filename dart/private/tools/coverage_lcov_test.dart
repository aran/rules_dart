import 'package:coverage/coverage.dart';
import 'package:test/test.dart';

import 'coverage_lcov.dart';

/// Where the collector reports a script, and the tracefile it writes; the
/// collection itself runs under `bazel coverage` in `e2e/dart_test_pkg`.
void main() {
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
}
