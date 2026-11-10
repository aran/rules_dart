// Checks the plan `outline_guard_modules` writes: see outline_guard.bzl.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final plan = jsonDecode(
    File(runfiles.rlocation(args.single)).readAsStringSync(),
  ) as Map<String, dynamic>;

  /// The kernel files of a module directory, by name.
  Map<String, List<int>> dills(String rlocation) => {
    for (final f in Directory(
      runfiles.rlocation(rlocation),
    ).listSync().whereType<File>())
      f.uri.pathSegments.last: f.readAsBytesSync(),
  };

  bool same(Map<String, List<int>> a, Map<String, List<int>> b) =>
      a.length == b.length &&
      a.keys.every((k) => b.containsKey(k) && _equal(a[k]!, b[k]!));

  group(
    'compiled against outlines, byte-identical to against full kernels',
    () {
      for (final pair in (plan['identical'] as List).cast<List<dynamic>>()) {
        final [full, outlined] = pair.cast<String>();
        test(full, () {
          final a = dills(full), b = dills(outlined);
          expect(a, isNotEmpty);
          expect(b.keys.toSet(), a.keys.toSet());
          for (final name in a.keys) {
            expect(
              _equal(a[name]!, b[name]!),
              isTrue,
              reason: '$name differs from $outlined/$name',
            );
          }
        });
      }
    },
  );

  group('an edit inside function bodies', () {
    for (final edit in (plan['edits'] as List).cast<Map<String, dynamic>>()) {
      test(edit['label'], () {
        final [modulesBefore, modulesAfter] = (edit['modules'] as List)
            .cast<String>();
        final [outlinesBefore, outlinesAfter] = (edit['outlines'] as List)
            .cast<String>();
        expect(outlinesBefore, endsWith('.outlines'));
        expect(
          same(dills(modulesBefore), dills(modulesAfter)),
          isFalse,
          reason: 'the edit leaves the full kernel unchanged',
        );
        final before = dills(outlinesBefore);
        expect(before, isNotEmpty);
        expect(
          same(before, dills(outlinesAfter)),
          edit['outline_changes'] == true ? isFalse : isTrue,
          reason: edit['outline_changes'] == true
              ? 'outline unchanged, though dependents copy positions from it'
              : 'outline changed',
        );
      });
    }
  });
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
