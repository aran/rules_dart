// A client of the SDK's analysis server, the process behind `dart analyze` and
// `dart fix`.
//
// The server runs from the SDK's JIT snapshot inside `analysis_host.dart`, one
// process started with the SDK's VM, `dartvm`, which ends itself when the
// process that started it is gone. Ending that process ends the server: it is
// never asked to shut down, so nothing waits on a shutdown. Not the `dart`
// launcher, which on Windows runs the VM as a child process: killing the
// launcher leaves the VM to end later, still holding the cache, and the host's
// parent would be the launcher, not this process.
//
// Its cache is a directory the caller names, not its default
// `$HOME/.dartServer`, which every process with that home shares.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Why a request failed: the server is gone.
class ServerExited implements Exception {
  ServerExited(this.exitCode);

  final int exitCode;

  @override
  String toString() =>
      'The analysis server exited unexpectedly (exit code $exitCode).';
}

/// A running analysis server.
class AnalysisServer {
  AnalysisServer._(this._process, this.cache) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive);
    _process.stderr.transform(utf8.decoder).listen(log.write);
    // Writing to a process that has exited fails the sink, not the write.
    _process.stdin.done.ignore();
    _process.exitCode.then((code) {
      final exited = _exited = ServerExited(code);
      for (final waiter in [..._pending.values, ?_idle, ?_analysis?.done]) {
        // Nobody may be waiting on it any more.
        waiter.future.ignore();
        if (!waiter.isCompleted) waiter.completeError(exited);
      }
      _pending.clear();
    });
  }

  /// Starts the server of the SDK whose `dart` is [dart] in the host at
  /// [host], for [command] (`analyze` or `fix`, as the server's client id
  /// names it), caching in [cache].
  ///
  /// [cache] is emptied first, and removed when the server ends.
  static Future<AnalysisServer> start(
    String dart, {
    required String host,
    required String command,
    required String cache,
    bool plugins = true,
  }) async {
    final sdk = File(dart).absolute.parent.parent.path;
    final cacheDir = Directory(cache).absolute;
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    cacheDir.createSync(recursive: true);
    final process = await Process.start(vm(dart), [
      host,
      cacheDir.path,
      '$sdk/bin/snapshots/analysis_server.dart.snapshot',
      '--suppress-analytics',
      '--client-id=dart-$command',
      '--disable-server-feature-completion',
      '--disable-server-feature-search',
      '--disable-status-notification-debouncing',
      '--disable-silent-analysis-exceptions',
      '--sdk',
      sdk,
      if (!plugins) '--no-plugins',
    ]);
    final server = AnalysisServer._(process, cacheDir);
    try {
      await server.request('server.setSubscriptions', {
        'subscriptions': ['STATUS'],
      });
    } on ServerExited {
      await server.kill();
      rethrow;
    }
    return server;
  }

  final Process _process;

  /// The server's cache directory.
  final Directory cache;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  var _id = 0;

  /// Why requests fail once the process has exited.
  ServerExited? _exited;

  /// Whether the server is analyzing, as its latest status said.
  var _busy = false;

  /// Completes at the next idle status.
  Completer<void>? _idle;

  /// The analysis [reanalyze] waits for: done at the first idle status after
  /// a busy one.
  ({Completer<void> done, bool started})? _analysis;

  /// The host process.
  int get pid => _process.pid;

  /// Whether the process is still running.
  bool get running => _exited == null;

  /// What the server wrote to stderr, and what it reported going wrong.
  final log = StringBuffer();

  /// The latest diagnostics for each file, by its absolute path.
  final errors = <String, List<Diagnostic>>{};

  /// Whether the server reported an error of its own.
  var serverError = false;

  /// Whether analyzer plugins ran: they keep state in [cache] by path, as
  /// the generated package and snapshot of each plugin set.
  bool get usedPlugins {
    final plugins = Directory('${cache.path}/.plugin_manager');
    return plugins.existsSync() && plugins.listSync().isNotEmpty;
  }

  /// Sends [method] and returns its result, or fails with [ServerExited] if
  /// the server has exited.
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    if (_exited case final exited?) return Future.error(exited);
    final id = '${++_id}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    return completer.future;
  }

  /// Analyzes [root] alone, whatever the server analyzed before, and
  /// completes when its diagnostics, and only its, are in [errors].
  ///
  /// Drops every root first: setting roots again rebuilds the server's
  /// contexts and empties its file content cache, so every file is read
  /// afresh. Setting the same roots again would be a no-op. What the server
  /// keeps across roots, its byte store, is keyed by content.
  Future<void> reanalyze(String root) async {
    await request('analysis.setAnalysisRoots', {
      'included': <String>[],
      'excluded': <String>[],
    });
    // The busy spell the reset may cause ends before the next idle can mean
    // that [root] is done.
    if (_busy) {
      final idle = _idle = Completer();
      await idle.future;
    }
    errors.clear();
    final analysis = _analysis = (done: Completer<void>(), started: false);
    await request('analysis.setAnalysisRoots', {
      'included': [canonical(root)],
      'excluded': <String>[],
    });
    await analysis.done.future;
  }

  /// Ends the server at once and removes its cache.
  ///
  /// The host is asked first (SIGTERM), so it removes the cache itself even
  /// if this process is killed in the meantime; it is killed if it has not
  /// ended within [_hostExit].
  Future<void> kill() async {
    _process.kill();
    await _process.exitCode.timeout(
      _hostExit,
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    try {
      cache.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or a file the server held open on Windows.
    }
  }

  void _receive(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      log.writeln(line);
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message) {
      case {
        'event': 'analysis.errors',
        'params': final Map<String, Object?> params,
      }:
        errors[params['file'] as String] = [
          for (final error in params['errors'] as List)
            Diagnostic(error as Map<String, Object?>),
        ];
      case {
        'event': 'server.status',
        'params': {'analysis': final Map<String, Object?> status},
      }:
        // As `dart analyze` reads it: done is the first idle status after a
        // busy one.
        _busy = status['isAnalyzing'] == true;
        if (_busy) {
          if (_analysis case (:final done, started: false)) {
            _analysis = (done: done, started: true);
          }
        } else {
          if (_idle case final idle? when !idle.isCompleted) idle.complete();
          if (_analysis case (:final done, started: true)
              when !done.isCompleted) {
            done.complete();
          }
        }
      case {
        'event': 'server.error' || 'server.pluginError',
        'params': final Map<String, Object?> error,
      }:
        serverError = true;
        log.writeln(
          'The analysis server reported an error: ${error['message']}',
        );
        if (error['stackTrace'] case final String trace when trace.isNotEmpty) {
          log.writeln(trace);
        }
      case {'id': final String id, 'error': final Map<String, Object?> error}:
        _pending
            .remove(id)
            ?.completeError(
              StateError(
                'The analysis server refused a request: '
                '${error['code']}: ${error['message']}',
              ),
            );
      case {'id': final String id}:
        _pending
            .remove(id)
            ?.complete(
              (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
            );
    }
  }
}

/// How long [AnalysisServer.kill] lets the host take to end on SIGTERM,
/// which takes it milliseconds.
const _hostExit = Duration(seconds: 5);

/// The VM, `dartvm`, of the SDK whose `dart` is [dart].
String vm(String dart) =>
    '${File(dart).absolute.parent.path}${Platform.pathSeparator}dartvm'
    '${Platform.isWindows ? '.exe' : ''}';

/// The directory [path] as the server takes it: absolute, without symlinks or
/// a trailing separator.
String canonical(String path) {
  final resolved = Directory(path).absolute.resolveSymbolicLinksSync();
  return resolved.length > 1 && resolved.endsWith(Platform.pathSeparator)
      ? resolved.substring(0, resolved.length - 1)
      : resolved;
}

/// One diagnostic, as the server reports it.
extension type Diagnostic(Map<String, Object?> json) {
  String get severity => json['severity'] as String;
  String get type => json['type'] as String;
  String get message => json['message'] as String;
  String? get correction => json['correction'] as String?;
  String get code => json['code'] as String;
  Map<String, Object?> get _location => (json['location'] as Map).cast();
  String get file => _location['file'] as String;
  int get offset => _location['offset'] as int;
  int? get line => _location['startLine'] as int?;
  int? get column => _location['startColumn'] as int?;
  List<Map<String, Object?>> get contextMessages => [
    for (final message in (json['contextMessages'] as List?) ?? const [])
      (message as Map).cast(),
  ];

  /// Errors first, then warnings, infos and anything else; then by file,
  /// offset and message, as `dart analyze` orders them.
  int compareTo(Diagnostic other) {
    final rank = _rank(severity).compareTo(_rank(other.severity));
    if (rank != 0) return rank;
    if (file != other.file) return file.compareTo(other.file);
    if (offset != other.offset) return offset - other.offset;
    return message.compareTo(other.message);
  }
}

int _rank(String severity) => switch (severity) {
  'ERROR' => 0,
  'WARNING' => 1,
  'INFO' => 2,
  _ => 3,
};
