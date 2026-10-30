// A client of the SDK's analysis server, the process behind `dart analyze` and
// `dart fix`, for build actions — a workaround for the hang below: it asks
// for what the action needs, then shuts the server down as they do, but kills
// it if the shutdown does not finish.
//
// On macOS the server's shutdown can block forever: closing its file watchers
// waits in dart:io's FSEvents `Node::Stop` for a release callback that never
// comes. `dart analyze` and `dart fix` await that shutdown without a timeout
// and report, or write, only after it, so an action running them hangs with
// its results never shown. An action keeps nothing of the server's, so a
// server that will not stop is ended, with a note in the action's log and on
// macOS a crash report of its threads: the record of the hang when it happens.
//
// The server is started as `dart analyze` starts it, with its cache in a
// directory the action owns. Its default, `$HOME/.dartServer`, is outside
// the action and shared by every process with that home.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running analysis server.
class AnalysisServer {
  AnalysisServer._(this._process, this._cache) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_receive);
    _process.stderr.transform(utf8.decoder).listen(log.write);
    _process.exitCode.then((code) {
      final error = _exited = StateError(
        'The analysis server exited unexpectedly (exit code $code).',
      );
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
      if (!_stopping && !_analyzed.isCompleted) _analyzed.completeError(error);
    });
  }

  /// Starts the server of the SDK whose `dart` is [dart], for [command]
  /// (`analyze` or `fix`, as the server's client id names it), caching in
  /// [cache].
  ///
  /// [cache] is emptied first and removed by [stop].
  static Future<AnalysisServer> start(
    String dart, {
    required String command,
    required String cache,
    bool plugins = true,
  }) async {
    final bin = File(dart).absolute.parent;
    final exe = Platform.isWindows ? '.exe' : '';
    final cacheDir = Directory(cache);
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    cacheDir.createSync(recursive: true);
    final process = await Process.start('${bin.path}/dartaotruntime$exe', [
      '${bin.path}/snapshots/analysis_server_aot.dart.snapshot',
      '--suppress-analytics',
      '--client-id=dart-$command',
      '--disable-server-feature-completion',
      '--disable-server-feature-search',
      '--disable-status-notification-debouncing',
      '--disable-silent-analysis-exceptions',
      '--sdk',
      bin.parent.path,
      '--cache=${cacheDir.absolute.path}',
      if (!plugins) '--no-plugins',
    ]);
    final server = AnalysisServer._(process, cacheDir);
    await server.request('server.setSubscriptions', {
      'subscriptions': ['STATUS'],
    });
    return server;
  }

  final Process _process;
  final Directory _cache;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  var _id = 0;
  var _stopping = false;

  /// Why requests fail once the process has exited: nothing reads its stdin
  /// or answers.
  StateError? _exited;
  Completer<void>? _analyzing;
  final _analyzed = Completer<void>();

  /// What the server wrote to stderr, and what it reported going wrong.
  final log = StringBuffer();

  /// The latest diagnostics for each file, by its absolute path.
  final errors = <String, List<Diagnostic>>{};

  /// Whether the server reported an error of its own.
  var serverError = false;

  /// Completes when analysis that started after [request]ing roots is done.
  Future<void> get analyzed => _analyzed.future;

  /// Sends [method] and returns its result, or fails at once if the server
  /// has exited.
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

  /// Analyzes [root] and completes when its diagnostics are in [errors].
  Future<void> analyze(String root) async {
    await request('analysis.setAnalysisRoots', {
      'included': [canonical(root)],
      'excluded': <String>[],
    });
    await analyzed;
  }

  /// Shuts the server down, or ends it if it has not finished within
  /// [_shutdownTimeout], and removes its cache.
  Future<void> stop() async {
    _stopping = true;
    try {
      await request('server.shutdown').timeout(_shutdownTimeout);
    } on TimeoutException {
      log.writeln(
        'The analysis server (process ${_process.pid}) did not shut down '
        'within ${_shutdownTimeout.inSeconds} seconds.',
      );
      // An action cannot sample it: macOS lets only a process with the
      // developer tools permission read a hardened binary's threads, and the
      // Bazel server has none. Aborting it has the system's crash reporter
      // record them, with the dispatch queue each runs on.
      if (Platform.isMacOS) {
        _process.kill(ProcessSignal.sigabrt);
        log.writeln(
          'It was aborted, so macOS writes its threads to '
          '~/Library/Logs/DiagnosticReports/dartaotruntime-<time>.ips.',
        );
        await _process.exitCode.timeout(_shutdownTimeout, onTimeout: () => 0);
      }
    } on StateError {
      // It exited before answering: there is nothing left to stop.
    }
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    try {
      _cache.deleteSync(recursive: true);
    } on FileSystemException {
      // A file the server held open on Windows: the next run clears it.
    }
  }

  void _receive(String line) {
    final message = jsonDecode(line);
    if (message is! Map<String, Object?>) return;
    switch (message) {
      case {'event': 'analysis.errors', 'params': final Map params}:
        errors[params['file'] as String] = [
          for (final error in params['errors'] as List)
            Diagnostic((error as Map).cast()),
        ];
      case {'event': 'server.status', 'params': {'analysis': final Map status}}:
        // As `dart analyze` reads it: done is the first idle status after a
        // busy one.
        if (status['isAnalyzing'] == true) {
          _analyzing ??= Completer();
        } else if (_analyzing != null && !_analyzed.isCompleted) {
          _analyzed.complete();
        }
      case {
        'event': 'server.error' || 'server.pluginError',
        'params': final Map error,
      }:
        serverError = true;
        log.writeln(
          'The analysis server reported an error: ${error['message']}',
        );
        if (error['stackTrace'] case final String trace when trace.isNotEmpty) {
          log.writeln(trace);
        }
      case {'id': final String id, 'error': final Map error}:
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

/// How long [AnalysisServer.stop] waits for a shutdown that takes
/// milliseconds when it works.
const _shutdownTimeout = Duration(seconds: 10);

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
