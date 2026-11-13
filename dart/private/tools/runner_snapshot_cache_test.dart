import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Drives the `dart_test` launcher of `test_runner_runner_fixture.dart`, a test
/// under `package:test`'s runner, to see its runner snapshot cache work.
///
/// The argument is the runfiles path of that test's executable.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final runnerLauncher = runfiles.rlocation(args[0]);
  // Whether the build caches the runner's snapshot
  // (`--@rules_dart//dart:runner_snapshot`).
  final cached = (jsonDecode(
    File(
      '${runnerLauncher.replaceFirst(RegExp(r'\.exe$'), '')}'
      '.launcher.json',
    ).readAsStringSync(),
  ) as Map).containsKey('runner_snapshot');

  // The runner starts from an app-JIT snapshot in a per-machine cache, which a
  // run trains when there is none. The cache cannot change a result, only how
  // fast the runner starts; anything that goes wrong with it is an error
  // naming the flag that turns it off, never a quiet run without it.
  group('the runner snapshot cache', () {
    const flag = '--@rules_dart//dart:runner_snapshot=false';
    late Directory tmp;
    late Directory cache;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('runner_snapshot_test.');
      cache = Directory('${tmp.path}/cache');
    });
    tearDown(() {
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
      }
      tmp.deleteSync(recursive: true);
    });

    /// Runs the runner fixture as `bazel test` would, with its cache in
    /// [directory] (by default `cache`).
    Future<ProcessResult> run({
      String? directory,
      Map<String, String> environment = const {},
    }) => Process.run(
      runnerLauncher,
      const [],
      environment: {
        for (final MapEntry(:key, :value) in Platform.environment.entries)
          // This test's own protocol files are not the fixture's.
          if (key != 'XML_OUTPUT_FILE' &&
              !key.startsWith('TESTBRIDGE_') &&
              !key.startsWith('TEST_SHARD') &&
              key != 'TEST_TOTAL_SHARDS')
            key: value,
        'RULES_DART_RUNNER_SNAPSHOT_DIR': directory ?? cache.path,
        ...environment,
      },
      includeParentEnvironment: false,
    );

    void expectPassed(ProcessResult result) => expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );

    void expectFailedNamingTheFlag(ProcessResult result, Matcher says) {
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect('${result.stderr}', allOf(contains(flag), says));
    }

    List<String> names() =>
        [for (final e in cache.listSync()) e.uri.pathSegments.last]..sort();

    List<File> snapshots() => [
      for (final e in cache.listSync())
        if (e is File && e.path.endsWith('.snapshot')) e,
    ];

    test('the second run starts from the snapshot the first trained', () async {
      final first = await run();
      expectPassed(first);
      expect('${first.stdout}', contains('All tests passed'));
      // One snapshot, and nothing of the training left beside it.
      expect(names(), [matches(RegExp(r'-[0-9a-f]{16}\.snapshot$'))]);
      final snapshot = snapshots().single;
      final trained = snapshot.readAsBytesSync();

      // Started from, not trained again: the same bytes, marked as used.
      final longAgo = DateTime(2001);
      snapshot.setLastModifiedSync(longAgo);
      final second = await run();
      expectPassed(second);
      expect('${second.stdout}', contains('All tests passed'));
      expect(snapshot.readAsBytesSync(), trained);
      expect(snapshot.lastModifiedSync().isAfter(longAgo), isTrue);

      // The VM is given the cached file: one it cannot start the runner from
      // fails the run, and is removed so that the next run trains again.
      snapshot.writeAsStringSync('not a snapshot');
      final refused = await run();
      expectFailedNamingTheFlag(
        refused,
        allOf(contains('did not start'), contains(snapshot.path)),
      );
      expect(snapshot.existsSync(), isFalse);
      expectPassed(await run());
      expect(snapshots(), hasLength(1));
    }, skip: cached ? false : 'the runner snapshot cache is off');

    test(
      'a cache directory that cannot be made fails, naming the flag',
      () async {
        final file = File('${tmp.path}/file')..writeAsStringSync('');
        final result = await run(directory: '${file.path}/cache');
        expectFailedNamingTheFlag(result, contains('${file.path}/cache'));
        expect('${result.stdout}', isNot(contains('All tests passed')));
      },
      skip: cached ? false : 'the runner snapshot cache is off',
    );

    test(
      'a cache directory that cannot be written fails, naming the flag',
      () async {
        cache.createSync();
        Process.runSync('chmod', ['a-w', cache.path]);
        final result = await run();
        expectFailedNamingTheFlag(result, contains(cache.path));
        expect('${result.stdout}', isNot(contains('All tests passed')));
      },
      skip: !cached
          ? 'the runner snapshot cache is off'
          : Platform.isWindows
          ? 'a read-only directory is a POSIX mode here'
          : false,
    );

    // A test that ends the VM itself stops it writing a snapshot. That
    // happens in the training run, after the test's own run has passed.
    test('training that writes no snapshot fails, naming the flag', () async {
      final result = await run(
        environment: {'RUNNER_FIXTURE_EXIT_IF_LOADED': '${tmp.path}/loaded'},
      );
      expectFailedNamingTheFlag(
        result,
        allOf(contains('training'), contains('hard exit')),
      );
      expect('${result.stdout}', contains('All tests passed'));
      expect(names(), isEmpty);
    }, skip: cached ? false : 'the runner snapshot cache is off');

    test('training keeps the newest snapshots and nothing else is touched', () async {
      cache.createSync();
      File snapshotFrom(int year) =>
          File(
              '${cache.path}/3.0.0-macos-arm64-${'$year'.padLeft(16, '0')}.snapshot',
            )
            ..writeAsStringSync('old')
            ..setLastModifiedSync(DateTime(year));
      // Nine, of which the seven used last stay beside the one trained now.
      final dropped = [snapshotFrom(2001), snapshotFrom(2002)];
      final kept = [
        for (var year = 2003; year < 2010; year++) snapshotFrom(year),
      ];
      final abandoned =
          File('${cache.path}/3.0.0-x-0000000000000000.snapshot.1.tmp')
            ..writeAsStringSync('')
            ..setLastModifiedSync(DateTime(2001));
      final unrelated = File('${cache.path}/notes.txt')..writeAsStringSync('');

      expectPassed(await run());
      expect(dropped.where((f) => f.existsSync()), isEmpty);
      expect(kept.every((f) => f.existsSync()), isTrue);
      expect(snapshots(), hasLength(8));
      expect(abandoned.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    }, skip: cached ? false : 'the runner snapshot cache is off');

    // The training selects no case itself; a run's tags must not reach it.
    test('a run whose tags select no case trains the snapshot', () async {
      final result = await run(environment: {'DART_TEST_TAGS': 'absent'});
      expectPassed(result);
      expect('${result.stderr}', contains('selects no case'));
      expect(snapshots(), hasLength(1));
      expectPassed(await run(environment: {'DART_TEST_TAGS': 'absent'}));
    }, skip: cached ? false : 'the runner snapshot cache is off');

    test('concurrent first runs all pass and leave one snapshot', () async {
      final results = await Future.wait([for (var i = 0; i < 3; i++) run()]);
      results.forEach(expectPassed);
      expect(names(), [matches(RegExp(r'\.snapshot$'))]);
    }, skip: cached ? false : 'the runner snapshot cache is off');

    test('with the cache off, nothing is cached', () async {
      expectPassed(await run());
      expect(cache.existsSync(), isFalse);
    }, skip: cached ? 'the runner snapshot cache is on' : false);
  });
}
