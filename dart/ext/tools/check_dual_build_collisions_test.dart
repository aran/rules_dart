import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rules_dart_check_dual_build_collisions/check_dual_build_collisions.dart';
import 'package:test/test.dart';

void main() {
  group('checkDualBuildCollisions', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('collision_check_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('clean tree yields no collisions', () {
      File(p.join(tmp.path, 'user.dart')).writeAsStringSync('class User {}');
      final report = checkDualBuildCollisions(tmp, ['.g.dart', '.freezed.dart']);
      expect(report.isEmpty, isTrue);
      expect(report.collisions, isEmpty);
    });

    test('committed .g.dart is flagged', () {
      File(p.join(tmp.path, 'user.dart')).writeAsStringSync('class User {}');
      File(p.join(tmp.path, 'user.g.dart'))
          .writeAsStringSync('// GENERATED');
      final report = checkDualBuildCollisions(tmp, ['.g.dart']);
      expect(report.collisions.length, 1);
      expect(report.collisions.single, endsWith('user.g.dart'));
    });

    test('multiple extensions are flagged independently', () {
      File(p.join(tmp.path, 'a.dart')).writeAsStringSync('');
      File(p.join(tmp.path, 'a.g.dart')).writeAsStringSync('');
      File(p.join(tmp.path, 'a.freezed.dart')).writeAsStringSync('');
      File(p.join(tmp.path, 'a.mocks.dart')).writeAsStringSync('');
      final report = checkDualBuildCollisions(
        tmp,
        ['.g.dart', '.freezed.dart', '.mocks.dart'],
      );
      expect(report.collisions.length, 3);
    });

    test('bazel-out and .dart_tool subtrees are pruned', () async {
      final bazelOut = Directory(p.join(tmp.path, 'bazel-out'))..createSync();
      File(p.join(bazelOut.path, 'leaked.g.dart')).writeAsStringSync('');
      final dartTool = Directory(p.join(tmp.path, '.dart_tool'))..createSync();
      File(p.join(dartTool.path, 'leaked.g.dart')).writeAsStringSync('');
      final git = Directory(p.join(tmp.path, '.git'))..createSync();
      File(p.join(git.path, 'leaked.g.dart')).writeAsStringSync('');
      final build = Directory(p.join(tmp.path, 'build'))..createSync();
      File(p.join(build.path, 'leaked.g.dart')).writeAsStringSync('');
      File(p.join(tmp.path, 'real.g.dart')).writeAsStringSync('');
      final report = checkDualBuildCollisions(tmp, ['.g.dart']);
      expect(report.collisions.length, 1);
      expect(report.collisions.single, endsWith('real.g.dart'));
    });

    test('non-existent directory throws', () {
      expect(
        () => checkDualBuildCollisions(
          Directory(p.join(tmp.path, 'missing')),
          ['.g.dart'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('loadBaselineExtensions', () {
    test('loads non-empty list from runfiles', () {
      final list = loadBaselineExtensions();
      expect(list, isNotEmpty);
      // Baseline invariants — these must stay filtered regardless.
      expect(list, contains('.g.dart'));
      expect(list, contains('.freezed.dart'));
    });

    test('every entry is a `.something.dart` suffix', () {
      final list = loadBaselineExtensions();
      for (final ext in list) {
        expect(ext.startsWith('.'), isTrue, reason: '$ext missing leading dot');
        expect(ext.endsWith('.dart'), isTrue,
            reason: '$ext is not a .dart extension');
      }
    });
  });
}
