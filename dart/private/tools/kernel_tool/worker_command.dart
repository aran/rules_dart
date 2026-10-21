import 'dart:async';
import 'dart:io';

import 'package:bazel_worker/bazel_worker.dart';

import 'args.dart';
import 'compile.dart';
import 'module_command.dart';

/// `kernel_tool module --snapshot <kernel_worker> --persistent_worker`: the
/// `module` command as a Bazel persistent worker, one work request being one
/// `module` run.
///
/// What a run costs most is starting `kernel_worker` and having it read every
/// dependency's kernel again. The worker keeps one `kernel_worker` for all its
/// requests, which its incremental compiler lets reuse what it has loaded; a
/// build compiles many targets that share dependencies. The snapshot comes
/// with the worker's own arguments, so a different SDK is a different worker.
Future<int> runWorker(List<String> startup) async {
  final at = startup.indexOf('--snapshot');
  if (at < 0 || at + 1 >= startup.length) {
    stderr.writeln('kernel_tool: a worker needs --snapshot <kernel_worker>');
    return 64;
  }
  final loop = _ModuleWorkerLoop(startup[at + 1]);
  return serve(
    loop.run,
    loop.close,
    Platform.isWindows ? const Stream.empty() : ProcessSignal.sigterm.watch(),
  );
}

/// Runs [run] until it ends or [stop] fires, then [close]s: 0 for an end, 143
/// (killed by SIGTERM) for a stop.
///
/// Bazel destroys a worker with SIGTERM. Left to its default, SIGTERM ends the
/// process wherever it is, and in the middle of starting a process that leaves
/// Dart's forked child holding the `kernel_worker`'s stdin open, so it never
/// sees end of input and never exits. Handled, the signal waits for the start
/// to finish and the worker stops its compiler itself.
Future<int> serve(
  Future<void> Function() run,
  Future<void> Function() close,
  Stream<Object?> stop,
) async {
  final stopped = Completer<int>();
  final watch = stop.listen((_) {
    if (!stopped.isCompleted) stopped.complete(143);
  });
  try {
    return await Future.any([run().then((_) => 0), stopped.future]);
  } finally {
    await watch.cancel();
    await close();
  }
}

class _ModuleWorkerLoop extends AsyncWorkerLoop {
  _ModuleWorkerLoop(this._snapshot);

  final String _snapshot;
  KernelWorker? _kernel;

  /// Where the worker started. A sandboxed request's paths are relative to
  /// its sandbox, which is a directory under this one.
  final _home = Directory.current.path;

  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final out = StringBuffer();
    var code = 0;
    final sandbox = request.sandboxDir;
    try {
      if (sandbox.isNotEmpty) {
        Directory.current = sandbox.startsWith('/')
            ? sandbox
            : '$_home/$sandbox';
      }
      final args = Args.parse('module', [
        ...request.arguments,
        '--snapshot',
        _snapshot,
      ]);
      final runtime = args.one('runtime');
      var kernel = _kernel;
      if (kernel != null && kernel.runtime != runtime) {
        await kernel.close();
        kernel = null;
      }
      kernel ??= _kernel = KernelWorker(runtime, _snapshot);
      code = await runModule(
        args,
        err: out,
        worker: kernel,
        digests: {for (final input in request.inputs) input.path: input.digest},
      );
    } on UsageException catch (e) {
      out.writeln(e);
      code = 64;
    } finally {
      Directory.current = _home;
    }
    return WorkResponse(exitCode: code, output: '$out');
  }

  Future<void> close() async => _kernel?.close();
}
