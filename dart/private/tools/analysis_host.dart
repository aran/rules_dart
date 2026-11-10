// Hosts the SDK's analysis server for the analyze and fix runners: run by the
// SDK's `dart` from source, it runs the server's JIT snapshot as an isolate of
// this one process, so ending the process ends the server, with nothing left
// to orphan.
//
//   dart analysis_host.dart <cache> <server snapshot> <server arguments>...
//
// The server reads requests from this process's stdin and writes to its
// stdout. It does not exit when stdin closes, so this process ends itself:
// when the process that started it is gone (on Windows not yet: a runner
// killed abruptly leaves its host until Bazel's server shuts down), on
// SIGTERM, or when the server isolate ends. It then removes <cache>, the
// server's cache directory, which nobody else would remove after a kill.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart analysis_host.dart <cache> <server snapshot> <arguments>...',
    );
    exit(64);
  }
  final cache = args[0];
  void end(int code) {
    try {
      Directory(cache).deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
    exit(code);
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => end(0));
    final getppid = DynamicLibrary.process()
        .lookupFunction<Int32 Function(), int Function()>('getppid');
    final parent = getppid();
    // A process whose parent dies is handed to another (init, or a
    // subreaper): its parent id changes.
    Timer.periodic(_parentPoll, (_) {
      if (getppid() != parent) end(0);
    });
  }

  final exited = ReceivePort();
  final errors = ReceivePort();
  var failed = false;
  errors.listen((error) {
    failed = true;
    stderr.writeln('The analysis server failed: $error');
  });
  await Isolate.spawnUri(
    Uri.file(args[1]),
    ['--cache=$cache', ...args.skip(2)],
    null,
    onExit: exited.sendPort,
    onError: errors.sendPort,
  );
  await exited.first;
  end(failed ? 70 : 0);
}

/// How often the host checks that its parent is alive: how long a server can
/// outlive a runner that was killed.
const _parentPoll = Duration(seconds: 1);
