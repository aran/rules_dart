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

  Future<Process> start(
    List<String> fixtureArgs, [
    Map<String, String> environment = const {},
  ]) => Process.start(launcher, fixtureArgs, environment: environment);

  // The runner snapshot cache the cases share that are not about the cache:
  // the first run trains it and the rest start from it, as runs on one machine
  // do, rather than each training its own. Not this machine's cache, which
  // this test has no need to fill.
  late Directory runnerCache;
  setUpAll(
    () => runnerCache = Directory.systemTemp.createTempSync('runner_cache.'),
  );
  tearDownAll(() => runnerCache.deleteSync(recursive: true));

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
        'RULES_DART_RUNNER_SNAPSHOT_DIR': runnerCache.path,
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

  // Where runfiles are only a manifest, a path from the stored kernel list
  // to a kernel leads nowhere, and outside `bazel test` there is no
  // TEST_TMPDIR: the launcher must find each kernel itself, write its list
  // somewhere of its own, and remove that when the test is done.
  group('run from a runfiles manifest, without TEST_TMPDIR', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('test_runner_run.'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Runs the launcher at [rlocationPath] from a manifest, leaving out the
    /// runfiles whose paths contain any of [without] and adding the lines [extra].
    Future<ProcessResult> runAsBazelRun(
      String rlocationPath, {
      List<String> without = const [],
      List<String> extra = const [],
      List<String> arguments = const [],
      Map<String, String> environment = const {},
    }) {
      var manifest =
          Platform.environment['RUNFILES_MANIFEST_FILE'] ??
          _manifestOf(Platform.environment['RUNFILES_DIR']!, tmp.path);
      if (without.isNotEmpty || extra.isNotEmpty) {
        final kept = File(manifest).readAsLinesSync().where(
          (line) =>
              line.isNotEmpty && !without.any(line.split(' ').first.contains),
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
          'RULES_DART_RUNNER_SNAPSHOT_DIR': runnerCache.path,
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

    // Only what the test brings is laid out: not the launcher's own files,
    // its program and its kernels, nor the rest of this test's runfiles,
    // whose manifest the fixture is given. The fixture brings its source
    // alone, and runs at its repository's root, where that is at its path.
    test('only the runfiles the test brings are laid out', () async {
      final result = await runAsBazelRun(args[0], arguments: ['files']);
      expectRan(result);
      final config = configOf(runfiles.rlocation(args[0]));
      expect('${result.stdout}'.trim().split(RegExp(r'\r?\n')), [
        config['test_path'],
      ]);
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
      final result = await runAsBazelRun(args[0], without: ['.modules']);
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
