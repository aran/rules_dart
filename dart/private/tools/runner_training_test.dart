// The test the `package:test` runner is trained on: `dart_test_runner_snapshot`
// runs it once under the runner and keeps the app-JIT snapshot that run wrote.
// It stays small, but touches the runner's usual paths: a group, `setUp`, and
// a couple of `expect`s.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('runner training', () {
    late List<int> values;

    setUp(() {
      values = [1, 2, 3];
    });

    test('compares a list', () {
      expect(values, hasLength(3));
      expect(values.first, equals(1));
    });

    test('compares a string', () {
      expect('bazel', contains('az'));
      // Keep the test isolate in its microtask drain until after
      // `RemoteListener` sends the `complete` message, then pause so the
      // runner isolate always closes `exitPort` before this isolate exits.
      void defer(int hops) {
        if (hops > 0) {
          Zone.root.scheduleMicrotask(() => defer(hops - 1));
        } else {
          sleep(const Duration(milliseconds: 100));
        }
      }

      defer(16);
    });
  });
}
