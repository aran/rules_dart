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
/// The worker keeps one `kernel_worker` process for all its requests, so a
/// target does not pay for starting it. What the compiler has loaded is reused
/// only between the modules of one request, keyed by the inputs' digests
/// (`module_command.dart`), and each request's compiler sees only the sources
/// that request declares. The snapshot comes with the worker's own arguments,
/// so a different SDK is a different worker.
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
      final inputs = requestInputs(request.inputs);
      code = await runModule(
        args,
        err: out,
        worker: kernel,
        digests: inputs,
        // Unsandboxed, the compiler could read anything under a kernel root;
        // Bazel's contract is that it reads only these.
        declaredInputs: inputs.keys.toList(),
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

/// A request's inputs and their digests, under each name the action knows
/// them by.
///
/// Under `--experimental_output_paths=strip` an action's arguments, and the
/// files in its sandbox, name every output directory `bazel-out/cfg/...`,
/// while Bazel lists the request's inputs under the configuration's own
/// `bazel-out/<config>/...`. Each output is therefore also listed as
/// `bazel-out/cfg/...`; without path mapping no argument names that.
Map<String, List<int>> requestInputs(Iterable<Input> inputs) {
  final out = <String, List<int>>{};
  for (final input in inputs) {
    out[input.path] = input.digest;
    final config = _outputDirectory.firstMatch(input.path);
    if (config != null) {
      out['bazel-out/cfg/${input.path.substring(config.end)}'] = input.digest;
    }
  }
  return out;
}

final _outputDirectory = RegExp(r'^bazel-out/[^/]+/');
