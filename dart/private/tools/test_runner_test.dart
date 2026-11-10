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
  // Whether the build links kernel lists (`--@rules_dart//dart:kernel_list`).
  final listed =
      (jsonDecode(
        File(
          '${launcher.replaceFirst(RegExp(r'\.exe$'), '')}'
          '.launcher.json',
        ).readAsStringSync(),
      ) as Map)['kernel_list'] ==
      true;

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
    /// runfiles whose paths contain [without].
    Future<ProcessResult> runAsBazelRun(
      String rlocationPath, {
      String? without,
    }) {
      var manifest =
          Platform.environment['RUNFILES_MANIFEST_FILE'] ??
          _manifestOf(Platform.environment['RUNFILES_DIR']!, tmp.path);
      if (without != null) {
        final kept = File(manifest)
            .readAsLinesSync()
            .where((line) => !line.split(' ').first.contains(without));
        manifest = (File(
          '${tmp.path}/MANIFEST.without',
        )..writeAsStringSync('${kept.join('\n')}\n')).path;
      }
      final temp = Directory('${tmp.path}/temp')..createSync();
      return Process.run(
        runfiles.rlocation(rlocationPath),
        const [],
        environment: {
          for (final MapEntry(:key, :value) in Platform.environment.entries)
            if (!key.startsWith('TEST') &&
                !key.startsWith('RUNFILES_') &&
                !key.endsWith('_RUNFILES') &&
                key != 'XML_OUTPUT_FILE')
              key: value,
          'RUNFILES_MANIFEST_FILE': manifest,
          // Where the launcher's own directories go, to see them removed.
          'TMPDIR': temp.path,
          'TEMP': temp.path,
          'TMP': temp.path,
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
/// would where it builds no tree: a line for each file, `<runfiles path> <real
/// path>`, and one for each linked directory (a tree artifact) whole.
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
