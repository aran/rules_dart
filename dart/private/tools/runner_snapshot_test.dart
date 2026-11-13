import 'dart:io';

import 'package:test/test.dart';

import 'runner_snapshot.dart';

/// The parts of the runner snapshot cache `runner_snapshot_cache_test` cannot
/// reach by running a launcher: the Linux cache's private directory, made here
/// in a directory of the test's own, and the key.
void main() {
  group('createPrivateDirectory', () {
    late Directory shared;
    setUp(() => shared = Directory.systemTemp.createTempSync('shared.'));
    tearDown(() => shared.deleteSync(recursive: true));

    test('makes the directory with mode 0700', () {
      final mine = Directory('${shared.path}/rules_dart-1');
      createPrivateDirectory(mine);
      expect(mine.statSync().mode & 0x1ff, 0x1c0);
      // And takes it as it is the next time.
      createPrivateDirectory(mine);
    });

    test('refuses one other users can reach', () {
      final open = Directory('${shared.path}/rules_dart-1')..createSync();
      Process.runSync('chmod', ['755', open.path]);
      expect(
        () => createPrivateDirectory(open),
        throwsA(
          isA<RunnerSnapshotException>().having(
            (e) => '$e',
            'message',
            allOf(contains('mode 755'), contains(runnerSnapshotFlag)),
          ),
        ),
      );
    });

    test('refuses a link', () {
      final target = Directory('${shared.path}/elsewhere')..createSync();
      Process.runSync('chmod', ['700', target.path]);
      final link = Link('${shared.path}/rules_dart-1')..createSync(target.path);
      expect(
        () => createPrivateDirectory(Directory(link.path)),
        throwsA(
          isA<RunnerSnapshotException>().having(
            (e) => '$e',
            'message',
            contains('is a link'),
          ),
        ),
      );
    });
  }, skip: Platform.isWindows ? 'POSIX modes' : false);

  group('keyOf', () {
    final digest = 'ab' * 32;

    test('names the VM and the start of the digest', () {
      expect(
        RunnerSnapshotCache.keyOf(vm: '3.13.7-linux-x64', digest: '$digest\n'),
        '3.13.7-linux-x64-abababababababab',
      );
    });

    test('keeps the name to characters any file system takes', () {
      expect(
        RunnerSnapshotCache.keyOf(vm: '3.14.0 dev/x', digest: digest),
        '3.14.0_dev_x-abababababababab',
      );
    });

    test('refuses a digest that is not a SHA-256, naming the flag', () {
      expect(
        () => RunnerSnapshotCache.keyOf(vm: 'v', digest: 'nope'),
        throwsA(
          isA<RunnerSnapshotException>().having(
            (e) => '$e',
            'message',
            contains(runnerSnapshotFlag),
          ),
        ),
      );
    });
  });
}
