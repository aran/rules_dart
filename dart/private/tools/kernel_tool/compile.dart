// Running the SDK's compilers: `kernel_worker` as a persistent worker for
// modules, `frontend_server` once for an entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:crypto/crypto.dart';

typedef CompileResult = ({int exitCode, String output});

/// What a file's digest is: the one Bazel gave in the work request, or else
/// a hash taken once. Scoped to one `module` run, since the files at a path
/// change between runs.
class Digests {
  Digests([this._given = const {}]);

  final Map<String, List<int>> _given;
  final _hashed = <String, List<int>>{};

  List<int> of(String path) =>
      _given[path] ??
      _hashed.putIfAbsent(
        path,
        () => sha256.convert(File(path).readAsBytesSync()).bytes,
      );
}

/// Compiles after which a `kernel_worker` is restarted. Its incremental
/// compiler keeps everything it has loaded, which in a Bazel worker is every
/// target built so far.
///
/// A count, not a memory reading: asking `ps` after each compile meant a
/// process start per module, and Bazel killing the worker during one leaves
/// Dart's forked child holding `kernel_worker`'s stdin open, so it never exits.
const maxCompiles = 100;

/// A `kernel_worker` that stays up between modules, so the platform and the
/// modules a compile reads are loaded once, not once per module. In a Bazel
/// worker it stays up between targets too, and is restarted after
/// [maxCompiles]; a restart costs a reload and changes no output, since what
/// it reuses is keyed by digests.
class KernelWorker {
  KernelWorker(this.runtime, this.snapshot);

  final String runtime;
  final String snapshot;

  BazelWorkerDriver? _driver;

  /// The compiler processes [_driver] started that have not yet exited, which
  /// [close] waits out.
  final _processes = <Process>[];

  /// Where the compiler process was started. Paths in a request are relative
  /// to the working directory, which a sandboxed worker has a new one of per
  /// request.
  String? _startedIn;
  var _requests = 0;
  var _compiles = 0;

  BazelWorkerDriver _start() => BazelWorkerDriver(
    () async {
      final process = await Process.start(runtime, [
        snapshot,
        '--persistent_worker',
      ]);
      process.stderr.listen(stderr.add);
      _processes.add(process);
      unawaited(process.exitCode.then((_) => _processes.remove(process)));
      return process;
    },
    maxWorkers: 1,
    // A request that kills the worker is a failed module, not a reason to run
    // it again.
    maxRetries: 0,
  );

  /// Compiles with [arguments]. [inputs] are the files the compile reads that
  /// can change between requests, whose digests tell the worker what it may
  /// reuse.
  Future<CompileResult> compile(
    List<String> arguments,
    List<String> inputs,
    Digests digests,
  ) async {
    final here = Directory.current.path;
    if (_startedIn != here) await close();
    _startedIn = here;
    final response = await (_driver ??= _start()).doWork(
      WorkRequest(
        arguments: arguments,
        inputs: [
          for (final path in inputs)
            Input(path: path, digest: digests.of(path)),
        ],
        requestId: ++_requests,
      ),
    );
    if (++_compiles >= maxCompiles) await close();
    return (exitCode: response.exitCode, output: response.output);
  }

  Future<void> close() async {
    final driver = _driver;
    _driver = null;
    _compiles = 0;
    await driver?.terminateWorkers();
    // Killing is not exiting: until it has, the process holds its working
    // directory, which Windows will not delete.
    await Future.wait([
      for (final p in [..._processes]) p.exitCode,
    ]);
  }
}

/// Runs [runtime] with [arguments], returning what it printed.
Future<CompileResult> runProcess(String runtime, List<String> arguments) async {
  const decoder = Utf8Codec(allowMalformed: true);
  final result = await Process.run(
    runtime,
    arguments,
    stdoutEncoding: decoder,
    stderrEncoding: decoder,
  );
  return (
    exitCode: result.exitCode,
    output: '${result.stdout}${result.stderr}',
  );
}

void deleteIfPresent(String path) {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
}

/// Writes [paths] one after another into [output]. A kernel file followed by
/// another is a kernel file, and the VM does not care in what order. Large
/// ones are streamed, not held in memory.
Future<void> concatenate(List<String> paths, String output) async {
  final sink = File(output).openWrite();
  try {
    for (final path in paths) {
      await sink.addStream(File(path).openRead());
    }
  } finally {
    await sink.close();
  }
}

/// What `frontend_server` printed in batch mode, separated into its protocol
/// lines and the compiler's own messages.
///
/// The protocol is a `result <id>` line, the diagnostics, a bare `<id>` line,
/// one `+<uri>` line per file read, and `<id> <output> <error count>`. A
/// failed compile exits 254, but the count is the authority.
class FrontendServerOutput {
  FrontendServerOutput(this.diagnostics, this.errorCount);

  factory FrontendServerOutput.parse(String output) {
    final lines = const LineSplitter().convert(output);
    String? id;
    for (final line in lines) {
      if (line.startsWith('result ')) {
        id = line.substring('result '.length).trim();
        break;
      }
    }
    int? errors;
    final kept = <String>[];
    for (final line in lines) {
      if (id != null) {
        if (line == 'result $id' || line == id) continue;
        if (line.startsWith('$id ')) {
          errors = int.tryParse(line.split(' ').last);
          continue;
        }
      }
      if (RegExp(r'^[+-][a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(line)) continue;
      kept.add(line);
    }
    return FrontendServerOutput(
      kept.isEmpty ? '' : '${kept.join('\n')}\n',
      errors,
    );
  }

  final String diagnostics;

  /// Null when the output has no result line.
  final int? errorCount;
}
