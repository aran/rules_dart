import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Drives the `dart_test` launcher of `test_runner_fixture.dart`, a test with a
/// plain `main`, which the launcher runs directly; and runs it, a test under
/// `package:test`'s runner and one with code assets as `bazel run` would.
///
/// The arguments are the runfiles paths of those tests' executables.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final launcher = runfiles.rlocation(args[0]);
  Map<Object?, Object?> configOf(String launcher) => jsonDecode(
    File(
      '${launcher.replaceFirst(RegExp(r'\.exe$'), '')}'
      '.launcher.json',
    ).readAsStringSync(),
  ) as Map;
  // Whether the build links kernel lists (`--@rules_dart//dart:kernel_list`).
  final listed = configOf(launcher)['kernel_list'] == true;
  final runnerLauncher = runfiles.rlocation(args[1]);
  // Whether the build caches the runner's snapshot
  // (`--@rules_dart//dart:runner_snapshot`).
  final cached = configOf(runnerLauncher).containsKey('runner_snapshot');

  Future<Process> start(
    List<String> fixtureArgs, [
    Map<String, String> environment = const {},
  ]) => Process.start(launcher, fixtureArgs, environment: environment);

  StreamIterator<String> lines(Stream<List<int>> stream) => StreamIterator(
    stream.transform(utf8.decoder).transform(const LineSplitter()),
  );

  // Bazel kills a test that hangs, so anything it printed is in test.log only
  // if the launcher passed it on as it came.
  test('passes output on while the test is still running', () async {
    final process = await start(['stream']);
    final out = lines(process.stdout);
    final err = lines(process.stderr);
    // A paused pipe left open would keep this test's own VM alive.
    addTearDown(() => Future.wait([out.cancel(), err.cancel()]));

    expect(await out.moveNext() ? out.current : null, 'stdout-ready');
    expect(await err.moveNext() ? err.current : null, 'stderr-ready');

    // Once the fixture has exited, stdin is gone and so is the echo.
    process.stdin.writeln('ping');
    unawaited(process.stdin.close().catchError((_) {}));
    expect(
      await out.moveNext() ? out.current : null,
      'echo:ping',
      reason: 'the launcher withheld output until the test exited',
    );
    expect(await process.exitCode, 0);
  });

  test('exits with the test, not with a process the test leaked', () async {
    final tmp = await Directory.systemTemp.createTemp('test_runner_test_');
    final release = File('${tmp.path}/release');
    final process = await start(['leak', release.path]);
    process.stderr.listen(stderr.add);

    // The lingering copy holds the launcher's stdout; it closes when that
    // copy is gone, which must happen before the directory goes away.
    final stdoutClosed = process.stdout.drain<void>();
    addTearDown(() async {
      release.writeAsStringSync('');
      await stdoutClosed;
      tmp.deleteSync(recursive: true);
    });

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('the launcher outlived the test it ran'),
    );
    expect(exitCode, 0);
  });

  // A plain `main` has no cases to select, so a filter must fail loudly
  // rather than run everything and report a filtered pass.
  test('a test without package:test refuses --test_filter', () async {
    final process = await start(['stream'], {'TESTBRIDGE_TEST_ONLY': 'x'});
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(
      err,
      contains('--test_filter needs a test written with package:test'),
    );
  });

  test('a test without package:test refuses DART_TEST_TAGS', () async {
    final process = await start(['stream'], {'DART_TEST_TAGS': 'unit'});
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(
      err,
      contains('DART_TEST_TAGS=unit needs a test written with package:test'),
    );
  });

  test('a test without package:test refuses DART_TEST_ORDERING_SEED', () async {
    final process = await start(['stream'], {'DART_TEST_ORDERING_SEED': '7'});
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(
      err,
      contains(
        'DART_TEST_ORDERING_SEED=7 needs a test written with package:test',
      ),
    );
  });

  // Cases are selected by `package:test` tags: the target's `include_tags`
  // and `exclude_tags`, narrowed for one run by DART_TEST_TAGS and
  // DART_TEST_EXCLUDE_TAGS. The fixture's target includes
  // `unit || integration` and excludes `slow`.
  group('tag selection', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('test_runner_tags.'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Runs the launcher at runfiles path [rlocationPath] as `bazel test`
    /// would, with [environment] added, and its runfiles from [manifest] alone
    /// when that is given.
    Future<ProcessResult> run(
      String rlocationPath, {
      Map<String, String> environment = const {},
      String? manifest,
    }) => Process.run(
      runfiles.rlocation(rlocationPath),
      const [],
      environment: {
        for (final MapEntry(:key, :value) in Platform.environment.entries)
          if (!key.startsWith('TESTBRIDGE_') &&
              !key.startsWith('TEST_SHARD') &&
              key != 'TEST_TOTAL_SHARDS' &&
              !key.startsWith('DART_TEST_') &&
              (manifest == null || !key.startsWith('RUNFILES_')))
            key: value,
        'XML_OUTPUT_FILE': '${tmp.path}/test.xml',
        'RULES_DART_RUNNER_SNAPSHOT_DIR': '${tmp.path}/cache',
        'RUNFILES_MANIFEST_FILE': ?manifest,
        ...environment,
      },
      includeParentEnvironment: false,
    );

    /// The cases [result] ran, from its report, after checking it passed.
    List<String> ran(ProcessResult result) {
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      final xml = File('${tmp.path}/test.xml').readAsStringSync();
      return [
        for (final m in RegExp(r'<testcase name="([^"]*)"').allMatches(xml))
          m[1]!,
      ]..sort();
    }

    test('the target\'s selection runs the cases it selects', () async {
      expect(ran(await run(args[3])), ['integration case', 'unit case']);
    });

    test('a run\'s include is intersected with the target\'s', () async {
      final result = await run(
        args[3],
        environment: {'DART_TEST_TAGS': 'integration'},
      );
      expect(ran(result), ['integration case']);
    });

    test('a run\'s include takes `dart test --tags` syntax', () async {
      // A comma joins selectors a case must all match; the library's own
      // `@Tags` count.
      final result = await run(
        args[3],
        environment: {'DART_TEST_TAGS': 'suite_tag,unit'},
      );
      expect(ran(result), ['unit case']);
    });

    test('a run\'s exclude is added to the target\'s', () async {
      final result = await run(
        args[3],
        environment: {'DART_TEST_EXCLUDE_TAGS': 'integration'},
      );
      expect(ran(result), ['unit case']);
    });

    test('tags and --test_filter both apply', () async {
      final result = await run(
        args[3],
        environment: {
          'DART_TEST_TAGS': 'unit || integration',
          'TESTBRIDGE_TEST_ONLY': 'integration',
        },
      );
      expect(ran(result), ['integration case']);
    });

    // So that `bazel test //... --test_env=DART_TEST_TAGS=x` passes every
    // target with no case tagged x.
    test(
      'a run\'s selection of no case passes, naming the suite\'s tags',
      () async {
        final result = await run(
          args[3],
          environment: {'DART_TEST_TAGS': 'absent'},
        );
        expect(ran(result), isEmpty);
        expect(
          '${result.stderr}',
          allOf(
            contains('DART_TEST_TAGS=absent selects no case of'),
            contains('Its tags: integration, slow, suite_tag, unit.'),
          ),
        );
      },
    );

    test(
      'a run\'s selection of no case says so for an untagged suite',
      () async {
        final result = await run(
          args[1],
          environment: {'DART_TEST_EXCLUDE_TAGS': 'absent || !absent'},
        );
        expect(ran(result), isEmpty);
        expect('${result.stderr}', contains('It uses no tags.'));
      },
    );

    // The runner shuffles with the seed and prints it, `random`'s too, so
    // test.log says how to repeat the order.
    test('DART_TEST_ORDERING_SEED shuffles the cases with that seed', () async {
      final result = await run(
        args[3],
        environment: {'DART_TEST_ORDERING_SEED': '7'},
      );
      expect(ran(result), ['integration case', 'unit case']);
      expect(
        '${result.stdout}',
        contains('Shuffling test order with --test-randomize-ordering-seed=7'),
      );
    });

    test('DART_TEST_ORDERING_SEED=random prints the seed it drew', () async {
      final result = await run(
        args[3],
        environment: {'DART_TEST_ORDERING_SEED': 'random'},
      );
      expect(ran(result), ['integration case', 'unit case']);
      expect(
        '${result.stdout}',
        matches(RegExp(r'--test-randomize-ordering-seed=\d+')),
      );
    });

    test('a DART_TEST_ORDERING_SEED the runner cannot read fails', () async {
      final result = await run(
        args[3],
        environment: {'DART_TEST_ORDERING_SEED': 'often'},
      );
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(
        '${result.stdout}${result.stderr}',
        contains('test-randomize-ordering-seed'),
      );
    });

    test('the target\'s selection of no case fails', () async {
      final result = await run(args[4]);
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(
        '${result.stderr}',
        allOf(
          contains('No tests match the requested tag selectors'),
          contains('include_tags = ["absent"] select no case of'),
        ),
      );
    });

    // The runner looks for `dart_test.yaml` in its working directory, the
    // test's package root, which a target's `data` may give one. What the
    // file would set, the target says. The fixture is in no package, so it
    // runs at its repository's root, where a manifest can add the file.
    test('a dart_test.yaml where the runner runs is not read', () async {
      final yaml = File('${tmp.path}/dart_test.yaml')
        ..writeAsStringSync('include_tags: absent\n');
      final config = configOf(runfiles.rlocation(args[1]));
      final listed = File(
        Platform.environment['RUNFILES_MANIFEST_FILE'] ??
            _manifestOf(Platform.environment['RUNFILES_DIR']!, tmp.path),
      ).readAsStringSync();
      final manifest = File('${tmp.path}/MANIFEST.with_yaml')
        ..writeAsStringSync(
          '$listed${config['working_directory']}/dart_test.yaml ${yaml.path}\n',
        );
      final result = await run(args[1], manifest: manifest.path);
      expect(ran(result), ['runs under the runner']);
    });
  });

  // A test that starts another target's launcher must not hand it this
  // launcher's settings, or that launcher runs this test's code.
  test('the test sees no RULES_DART_ variables but Bazel\'s own', () async {
    final result = await Process.run(
      launcher,
      ['env'],
      environment: {'RULES_DART_SOMETHING': 'parent'},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final names = '${result.stdout}'.trim().split(RegExp(r'\r?\n'));
    expect(names.where((n) => n.startsWith('RULES_DART_')), isEmpty);
    expect(names, contains('TEST_TMPDIR'));
    expect(
      names.toSet().intersection({'RUNFILES_DIR', 'RUNFILES_MANIFEST_FILE'}),
      isNotEmpty,
    );
  });

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

  // Where runfiles are only a manifest, a path from the stored kernel list
  // to a kernel leads nowhere, and outside `bazel test` there is no
  // TEST_TMPDIR: the launcher must find each kernel itself, write its list
  // somewhere of its own, and remove that when the test is done.
  group('run from a runfiles manifest, without TEST_TMPDIR', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('test_runner_run.'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Runs the launcher at [rlocationPath] from a manifest, leaving out the
    /// runfiles whose paths contain [without] and adding the lines [extra].
    Future<ProcessResult> runAsBazelRun(
      String rlocationPath, {
      String? without,
      List<String> extra = const [],
      List<String> arguments = const [],
      Map<String, String> environment = const {},
    }) {
      var manifest =
          Platform.environment['RUNFILES_MANIFEST_FILE'] ??
          _manifestOf(Platform.environment['RUNFILES_DIR']!, tmp.path);
      if (without != null || extra.isNotEmpty) {
        final kept = File(manifest).readAsLinesSync().where(
          (line) =>
              line.isNotEmpty &&
              (without == null || !line.split(' ').first.contains(without)),
        );
        manifest = (File(
          '${tmp.path}/MANIFEST.edited',
        )..writeAsStringSync('${[...kept, ...extra].join('\n')}\n')).path;
      }
      final temp = Directory('${tmp.path}/temp')..createSync();
      return Process.run(
        runfiles.rlocation(rlocationPath),
        arguments,
        environment: {
          for (final MapEntry(:key, :value) in Platform.environment.entries)
            if (!key.startsWith('TEST') &&
                !key.startsWith('RUNFILES_') &&
                !key.endsWith('_RUNFILES') &&
                key != 'XML_OUTPUT_FILE')
              key: value,
          'RUNFILES_MANIFEST_FILE': manifest,
          // Not this machine's cache, which this test has no need to fill.
          'RULES_DART_RUNNER_SNAPSHOT_DIR': '${tmp.path}/cache',
          // Where the launcher's own directories go, to see them removed.
          'TMPDIR': temp.path,
          'TEMP': temp.path,
          'TMP': temp.path,
          ...environment,
        },
        includeParentEnvironment: false,
        workingDirectory: tmp.path,
      );
    }

    void expectRan(ProcessResult result) {
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(Directory('${tmp.path}/temp').listSync(), isEmpty);
    }

    test('a test with a plain main', () async {
      expectRan(await runAsBazelRun(args[0]));
    });

    // The runfiles are laid out as a tree holds them, so a test reads by its
    // path what it would read in one: its `data`, its libraries' resources,
    // and another repository's `data` beside its own.
    test('runfiles are laid out as a tree holds them', () async {
      expectRan(
        await runAsBazelRun(
          args[5],
          // What the fixture's `env` gives it under `bazel test`.
          environment: {'EXTERNAL_RLOCATIONPATH': args[6]},
        ),
      );
    });

    // The launcher's own files, its program and its kernels, are not copied.
    test('the launcher\'s own files are not laid out', () async {
      final result = await runAsBazelRun(args[0], arguments: ['files']);
      expectRan(result);
      final config = configOf(runfiles.rlocation(args[0]));
      // It runs at its repository's root, where a main-repository file is
      // at its `short_path`.
      final own = File(runfiles.rlocation(config['own_files'] as String))
          .readAsLinesSync()
          .where((p) => p.isNotEmpty && !p.startsWith('../'));
      final laidOut = '${result.stdout}'.trim().split(RegExp(r'\r?\n'));
      expect(own, isNotEmpty);
      expect(laidOut, contains(config['test_path']));
      expect(laidOut.toSet().intersection(own.toSet()), {config['test_path']});
    });

    // A repository's files can be symlinks, as a git package's are; each is
    // laid out as what it points at, alone or inside a directory.
    test('symlinked runfiles are laid out', () async {
      final workspace = configOf(runfiles.rlocation(args[0]))['workspace'];
      final real = File('${tmp.path}/real.txt')..writeAsStringSync('x');
      final link = Link('${tmp.path}/link.txt')..createSync('real.txt');
      final tree = Directory('${tmp.path}/tree')..createSync();
      File('${tree.path}/real.txt').writeAsStringSync('x');
      Link('${tree.path}/link.txt').createSync('real.txt');
      final result = await runAsBazelRun(
        args[0],
        arguments: ['files'],
        extra: [
          '$workspace/linked.txt ${link.path}',
          '$workspace/plain.txt ${real.path}',
          '$workspace/tree ${tree.path}',
        ],
      );
      expectRan(result);
      expect(
        '${result.stdout}'.trim().split(RegExp(r'\r?\n')),
        containsAll([
          'linked.txt',
          'plain.txt',
          'tree/real.txt',
          'tree/link.txt',
        ]),
      );
    });

    test('a test under the runner', () async {
      final result = await runAsBazelRun(args[1]);
      expectRan(result);
      expect('${result.stdout}', contains('All tests passed'));
    });

    test('a test whose code assets resolve beside its kernel', () async {
      expectRan(await runAsBazelRun(args[2]));
    });

    // Never a quiet second way: a list that cannot be followed fails, and
    // says how to build without lists.
    test('a kernel missing from runfiles fails, naming the flag', () async {
      final result = await runAsBazelRun(args[0], without: '.modules');
      expect(result.exitCode, 1, reason: '${result.stdout}');
      expect(
        '${result.stderr}',
        allOf(
          contains('which is not in runfiles'),
          contains('set --@rules_dart//dart:kernel_list=false'),
        ),
      );
      expect(Directory('${tmp.path}/temp').listSync(), isEmpty);
    }, skip: listed ? false : 'kernel lists are off');
  });
}

/// Writes the manifest of the runfiles tree at [root] into [into], as Bazel
/// would where it builds no tree: a line for each file,
/// `<runfiles path> <real path>`, and one for each linked directory (a tree
/// artifact) whole.
String _manifestOf(String root, String into) {
  final lines = <String>[];
  void walk(Directory directory, String prefix) {
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.path.substring(directory.path.length + 1);
      final path = prefix.isEmpty ? name : '$prefix/$name';
      if (entity is Link) {
        lines.add('$path ${entity.resolveSymbolicLinksSync()}');
      } else if (entity is Directory) {
        walk(entity, path);
      } else if (name != 'MANIFEST' || prefix.isNotEmpty) {
        lines.add('$path ${entity.path}');
      }
    }
  }

  walk(Directory(root), '');
  final manifest = File('$into/MANIFEST')
    ..writeAsStringSync('${lines.join('\n')}\n');
  return manifest.path;
}
