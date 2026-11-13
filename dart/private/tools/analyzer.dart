// What the analyze and fix runners need of the SDK's analyzer: `dart analyze`
// and `dart fix --apply`, run over a staged project in a build action.
//
// Two implementations behave alike. `DartCli` runs the plain commands, a fresh
// process per action. `ServerAnalyzer` drives the analysis server they start,
// and keeps it across a persistent worker's requests. The runners take the
// second when their arguments name the server's host (`--host`), which the
// `dart_analyze` aspect does unless `--@rules_dart//dart:analysis_worker` is
// off; see `runAnalysisAction` for how a runner serves a worker.
import 'dart:ffi';
import 'dart:io';

import 'package:bazel_worker/bazel_worker.dart';

import 'dart_cli.dart';
import 'server_analyzer.dart';

/// What a command printed, and its exit code.
typedef Output = ({int exitCode, String stdout, String stderr});

/// `dart analyze` and `dart fix --apply`, as a build action runs them.
abstract interface class Analyzer {
  /// Analyzes [project] with the SDK of [dart], as
  /// `dart analyze [--fatal-infos] <project>` does, naming files inside
  /// [project] relative to it.
  Future<Output> analyze(
    String dart,
    String project, {
    required bool fatalInfos,
  });

  /// Fixes the project at [root] in place with the SDK of [dart], as
  /// `dart fix --apply <root>` does.
  Future<Output> fix(String dart, String root);
}

/// What an action reports, and its exit code.
typedef Result = ({int exitCode, String output});

/// Picks the analyzer for one action: the server hosted by `host` when the
/// action names one, else [DartCli] caching in `cache`, a path the action
/// owns.
typedef Analyzers = Analyzer Function({String? host, required String cache});

/// Runs one action of a runner, given its arguments.
typedef Action = Future<Result> Function(
  List<String> args,
  Analyzers analyzers,
);

/// Runs [action] as a runner's `main` with [args]: once, or for every work
/// request when Bazel starts the runner as a persistent worker.
///
/// Once, the arguments may be a `@flagfile`, and a server lives for the one
/// action, its cache beside the action's outputs. As a worker, each request's
/// arguments follow the worker's own, and one [ServerAnalyzer] serves them
/// all, caching in directories of this worker's (see [workerCache]).
Future<Never> runAnalysisAction(List<String> args, Action action) async {
  if (!args.contains('--persistent_worker')) {
    ServerAnalyzer? server;
    final result = await action(expandFlagfiles(args), ({
      String? host,
      required String cache,
    }) {
      if (host == null) return DartCli(cache: cache);
      return server ??= ServerAnalyzer(host: host, cache: cache);
    });
    await server?.close();
    // Bazel shows both streams of a failed action, and of a clean one only
    // what it printed: the action decides by what it reports.
    stderr.write(result.output);
    exit(result.exitCode);
  }
  final worker = _AnalysisWorker([
    for (final arg in args)
      if (arg != '--persistent_worker') arg,
  ], action);
  if (!Platform.isWindows) {
    // Bazel ends a worker with SIGTERM, a busy one too: nothing of the
    // server's is worth waiting for.
    ProcessSignal.sigterm.watch().listen((_) async {
      await worker.close();
      exit(143);
    });
  }
  await worker.run();
  await worker.close();
  exit(0);
}

/// Where a worker's servers cache, as `<this>-<n>`: in the system's temporary
/// directory, where neither the sandbox's cleanup nor another worker reaches.
///
/// A worker may write only in its working directory and its temporary
/// directory. Sandboxed, Bazel cleans the working directory's parent for each
/// request, and hardened (`--experimental_worker_sandbox_hardening`) it gives
/// the worker a `/tmp` of its own and makes the rest read-only. The process id
/// keeps workers that share a temporary directory apart.
String workerCache() =>
    '${Directory.systemTemp.absolute.path}'
    '${Platform.pathSeparator}dart_analysis_worker-$pid';

/// Removes from [dir] the server caches of workers that are gone.
///
/// A server removes its cache when it ends, but nothing does when its
/// worker and it are killed together, as Bazel's process group is when its
/// server is, or its job object on Windows. A worker clears such leftovers
/// when it starts. A server whose worker alone is killed ends within a second
/// or so and removes its own (`analysis_host.dart`).
void removeOrphanedCaches(String dir) {
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(dir).listSync();
  } on FileSystemException {
    return;
  }
  for (final entry in entries) {
    final owner = _cacheOwner.firstMatch(
      entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    if (entry is! Directory || owner == null) continue;
    final worker = int.parse(owner[1]!);
    if (worker == pid || _running(worker)) continue;
    try {
      entry.deleteSync(recursive: true);
    } on FileSystemException {
      // Gone already, or held open by a server still ending, which removes it
      // as it ends.
    }
  }
}

/// Whether process [id] is running. An id handed on to a new process keeps
/// an orphaned cache until that process ends too.
bool _running(int id) {
  // `kill -0` succeeds for a process that exists.
  if (!Platform.isWindows) {
    return Process.runSync('kill', ['-0', '$id']).exitCode == 0;
  }
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final openProcess = kernel32
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
  final waitFor = kernel32
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject',
      );
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  const synchronize = 0x00100000; // SYNCHRONIZE
  const waitTimeout = 0x102; // WAIT_TIMEOUT
  final process = openProcess(synchronize, 0, id);
  // No such process.
  if (process == 0) return false;
  try {
    // An ended process stays open while a handle to it is held, signalled.
    return waitFor(process, 0) == waitTimeout;
  } finally {
    closeHandle(process);
  }
}

final _cacheOwner = RegExp(r'^dart_analysis_worker-(\d+)-\d+$');

/// [args] with each `@file` replaced by the file's lines.
List<String> expandFlagfiles(List<String> args) => [
  for (final arg in args)
    if (arg.startsWith('@'))
      ...File(arg.substring(1)).readAsLinesSync().where((l) => l.isNotEmpty)
    else
      arg,
];

class _AnalysisWorker extends AsyncWorkerLoop {
  _AnalysisWorker(this._startup, this._action);

  final List<String> _startup;
  final Action _action;

  /// Where the worker started. A sandboxed request's paths are relative to
  /// its sandbox, a directory under this one.
  final _home = Directory.current.path;
  ServerAnalyzer? _server;

  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final sandbox = request.sandboxDir;
    Directory.current = sandbox.isEmpty
        ? _home
        : Directory(sandbox).isAbsolute
        ? sandbox
        : '$_home/$sandbox';
    try {
      final result = await _action([..._startup, ...request.arguments], ({
        String? host,
        required String cache,
      }) {
        if (host == null) return DartCli(cache: cache);
        if (_server case final server?) return server;
        final caches = workerCache();
        removeOrphanedCaches(File(caches).parent.path);
        return _server = ServerAnalyzer(
          // Its own file, not a sandbox's link to it, which the next request
          // may remove.
          host: File(host).resolveSymbolicLinksSync(),
          cache: caches,
          note: stderr.writeln,
        );
      });
      return WorkResponse(exitCode: result.exitCode, output: result.output);
    } catch (e, stack) {
      return WorkResponse(exitCode: 1, output: '$e\n$stack\n');
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
  }
}
