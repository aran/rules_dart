import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `analysis_host.dart` ends itself, and removes its cache, when the process
/// that started it is gone: macOS and Linux notice a change of parent, Windows
/// holds a handle to the parent it started under.
///
/// The host runs as the runner starts it, with `dartvm`, but over a server
/// that only reports it is up. Its parent is an intermediary that is killed,
/// as an abruptly killed runner is. Arguments are the runfiles paths of
/// `analysis_host.dart` and a copy of the SDK's `run` file set: the VM the
/// host runs on and no more, since a test lays out each of its files.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  // The VM itself, as a runner is one process: not the `dart` launcher, which
  // on Windows runs the VM as its child.
  final dartvm =
      '${runfiles.rlocation(args[1])}/bin/dartvm'
      '${Platform.isWindows ? '.exe' : ''}';
  final host = File(runfiles.rlocation(args[0])).resolveSymbolicLinksSync();

  late Directory scratch;
  int? hostPid;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('analysis_host_test');
    File('${scratch.path}/server.dart').writeAsStringSync('''
import 'dart:io';
import 'dart:isolate';

void main(List<String> args) {
  File(args.last).writeAsStringSync('up');
  ReceivePort().listen((_) {});
}
''');
    File('${scratch.path}/intermediary.dart').writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final host = await Process.start(args.first, args.skip(1).toList());
  host.stdout.drain<void>();
  host.stderr.drain<void>();
  print(host.pid);
  await Future<void>.delayed(const Duration(days: 1));
}
''');
  });
  tearDown(() {
    if (hostPid case final pid?) Process.killPid(pid, ProcessSignal.sigkill);
    hostPid = null;
    scratch.deleteSync(recursive: true);
  });

  Future<void> until(bool Function() condition, Duration within) async {
    final end = DateTime.now().add(within);
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(condition(), isTrue);
  }

  test('ends and removes its cache when its parent is killed', () async {
    final cache = Directory('${scratch.path}/cache')..createSync();
    final ready = File('${scratch.path}/ready');
    final intermediary = await Process.start(dartvm, [
      '${scratch.path}/intermediary.dart',
      dartvm,
      host,
      cache.path,
      '${scratch.path}/server.dart',
      ready.path,
    ]);
    addTearDown(() => intermediary.kill(ProcessSignal.sigkill));
    intermediary.stderr.drain<void>();
    final lines = intermediary.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    hostPid = int.parse(await lines.first.timeout(const Duration(minutes: 1)));

    // Up, with its parent alive: it stays, across several checks of the
    // parent.
    await until(ready.existsSync, const Duration(minutes: 1));
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(cache.existsSync(), isTrue, reason: 'the host ended on its own');

    intermediary.kill(ProcessSignal.sigkill);
    await intermediary.exitCode;
    await until(() => !cache.existsSync(), const Duration(seconds: 20));
  });
}
