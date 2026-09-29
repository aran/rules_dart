import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Drives the `dart_test` launcher against `test_runner_fixture.dart`.
///
/// Arguments are the runfiles paths of the launcher and the fixture's kernel.
/// The launcher finds the VM through `RULES_DART_DART`, which this test
/// inherits from its own launcher, and is pointed at the fixture through
/// `RULES_DART_DILL`.
void main(List<String> args) {
  final launcher = Runfiles.create().rlocation(args[0]);

  Future<Process> start(List<String> fixtureArgs) => Process.start(
    launcher,
    fixtureArgs,
    // This test itself runs under the `package:test` runner; the fixture is a
    // plain `main`, run directly.
    environment: {'RULES_DART_DILL': args[1], 'RULES_DART_TEST_RUNNER': ''},
  );

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
    final process = await Process.start(
      launcher,
      ['stream'],
      environment: {
        'RULES_DART_DILL': args[1],
        'RULES_DART_TEST_RUNNER': '',
        'TESTBRIDGE_TEST_ONLY': 'anything',
      },
    );
    final err = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    expect(await process.exitCode, 1);
    expect(
      err,
      contains('--test_filter needs a test written with package:test'),
    );
  });
}
