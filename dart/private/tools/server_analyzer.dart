// `Analyzer` by driving the analysis server directly, printing and fixing as
// `dart analyze` and `dart fix --apply` do (see `analysis_server.dart`).
//
// One `ServerAnalyzer` keeps its server across requests, which is what a
// persistent worker is for: the server has already loaded the SDK and the
// analyzer's own code, and its byte store holds what it has computed. Each
// request is answered from a reset server (`AnalysisServer.reanalyze`), so a
// request sees only its own files.
import 'dart:async';
import 'dart:io';

import 'analysis_server.dart';
import 'analyzer.dart';

/// Asks the SDK's analysis server for what `dart analyze` and `dart fix`
/// would.
class ServerAnalyzer implements Analyzer {
  /// Hosts servers in [host] (`analysis_host.dart`), each caching in
  /// `<cache>-<n>`, a directory this analyzer owns while the server runs.
  ///
  /// A server is stopped once it has had nothing to do for [idle], and
  /// [note] hears when servers start and stop.
  ServerAnalyzer({
    required this._host,
    required String cache,
    this.idle = idleGap,
    void Function(String)? note,
  }) : _cache = Directory(cache).absolute.path,
       _note = note ?? ((_) {});

  final String _host;
  final String _cache;
  final void Function(String) _note;

  /// How long a server is kept with nothing to do.
  final Duration idle;

  _Live? _live;
  Timer? _idleTimer;
  var _servers = 0;

  /// The host process of the running server, if one runs.
  int? get serverPid => _live?.server.pid;

  @override
  Future<Output> analyze(
    String dart,
    String project, {
    required bool fatalInfos,
  }) => _serve(dart, 'analyze', (server) async {
    await server.reanalyze(project);
    final output = outputOf(server, project, fatalInfos: fatalInfos);
    // Plugin state is kept in the cache by path, and reused by mtime: a
    // request that ran plugins leaves the next one a fresh server.
    if (server.usedPlugins) await _stop('analyzer plugins ran');
    return output;
  });

  @override
  Future<Output> fix(String dart, String root) =>
      _serve(dart, 'fix', (server) async {
        final overlaid = <String>{};
        String? refusal;
        try {
          refusal = await _applyFixes(server, root, overlaid);
        } finally {
          await _dropOverlays(server, overlaid);
        }
        return (
          exitCode: refusal == null ? 0 : 3,
          stdout: refusal == null ? '' : 'Unable to compute fixes: $refusal\n',
          stderr: server.log.toString(),
        );
      });

  /// Stops the server, if one runs.
  Future<void> close() async {
    _idleTimer?.cancel();
    await _stop('closing');
  }

  /// Runs [work] on a server for [command], from the SDK of [dart]; once
  /// more on a fresh server if the server exits during it.
  Future<Output> _serve(
    String dart,
    String command,
    Future<Output> Function(AnalysisServer) work,
  ) async {
    _idleTimer?.cancel();
    try {
      for (var attempt = 1; ; attempt++) {
        final server = await _serverFor(dart, command);
        server.log.clear();
        server.serverError = false;
        try {
          return await work(server);
        } on ServerExited catch (e) {
          final log = server.log.toString();
          await _stop('$e');
          if (attempt == 2) {
            return (
              exitCode: 4,
              stdout: '',
              stderr: '$e It exited again on a fresh server.\n$log',
            );
          }
        }
      }
    } finally {
      _idleTimer = Timer(idle, () => _stop('idle for ${idle.inSeconds} s'));
    }
  }

  Future<AnalysisServer> _serverFor(String dart, String command) async {
    final real = File(dart).absolute.resolveSymbolicLinksSync();
    final identity = sdkIdentity(real);
    if (_live case final live?
        when live.server.running &&
            live.identity == identity &&
            live.command == command) {
      return live.server;
    }
    if (_live != null) await _stop('the request needs another server');
    final cache = '$_cache-${++_servers}';
    final server = await AnalysisServer.start(
      real,
      host: _host,
      command: command,
      cache: cache,
      // `dart fix` turns plugins off: they cannot bulk fix.
      plugins: command != 'fix',
    );
    _note(
      'Started the analysis server for `dart $command` '
      '(process ${server.pid}, SDK $identity, cache $cache).',
    );
    _live = (server: server, identity: identity, command: command);
    return server;
  }

  Future<void> _stop(String why) async {
    final live = _live;
    _live = null;
    if (live == null) return;
    await live.server.kill();
    _note('Stopped the analysis server (process ${live.server.pid}): $why.');
  }
}

typedef _Live = ({AnalysisServer server, String identity, String command});

/// How long a worker keeps a server that has nothing to do: long enough to
/// outlast the gaps between a build's analysis actions, short enough that the
/// server ends with the build. Measured on this repository, rebuilding after
/// an edit to a library most of it depends on, under a load of 70 to 90 on 16
/// cores: a worker's gaps between requests had a median of 1.7 s, and the
/// longest was 52 s, while it waited for compiles.
const idleGap = Duration(seconds: 60);

/// What makes the SDK whose `dart` is at [dart] the SDK it is: its version
/// and its server snapshot, not where it is. One path may hold another SDK
/// later.
String sdkIdentity(String dart) {
  final sdk = File(dart).parent.parent.path;
  final version = File('$sdk/version').readAsStringSync().trim();
  final snapshot = File('$sdk/bin/snapshots/analysis_server.dart.snapshot')
      .statSync();
  return '$version, server snapshot of ${snapshot.size} bytes from '
      '${snapshot.modified.toUtc().toIso8601String()}';
}

/// What `dart analyze [--fatal-infos]` prints and exits with for what
/// [server] reported of [project].
Output outputOf(
  AnalysisServer server,
  String project, {
  required bool fatalInfos,
}) {
  final diagnostics = [
    for (final errors in server.errors.values)
      // `dart analyze` leaves out TODO comments, which the server reports
      // as infos.
      for (final error in errors)
        if (error.type != 'TODO' || error.severity != 'INFO') error,
  ];
  final code = _exitCode(diagnostics, fatalInfos: fatalInfos);
  return (
    exitCode: server.serverError ? 4 : code,
    stdout: _report(diagnostics, project),
    stderr: server.log.toString(),
  );
}

/// `dart analyze`'s exit code for [diagnostics]: 3 for an error, 2 for a
/// warning, 1 for an info under [fatalInfos], else 0. Warnings are always
/// fatal here, as `dart analyze` makes them by default.
int _exitCode(List<Diagnostic> diagnostics, {required bool fatalInfos}) {
  final severities = {for (final d in diagnostics) d.severity};
  if (severities.contains('ERROR')) return 3;
  if (severities.contains('WARNING')) return 2;
  if (fatalInfos && severities.contains('INFO')) return 1;
  return 0;
}

/// [diagnostics] in `dart analyze`'s default format, with paths relative to
/// [project]: those in `pubspec.yaml` and `analysis_options.yaml` errors
/// first, as possible causes of the rest.
String _report(List<Diagnostic> diagnostics, String project) {
  if (diagnostics.isEmpty) return 'No issues found!\n';
  final root = canonical(project);
  bool priority(Diagnostic d) =>
      d.severity == 'ERROR' &&
      const {
        'pubspec.yaml',
        'analysis_options.yaml',
      }.contains(d.file.split(Platform.pathSeparator).last);
  final first = diagnostics.where(priority).toList()..sort(_byOrder);
  final rest = diagnostics.where((d) => !priority(d)).toList()..sort(_byOrder);
  final out = StringBuffer();

  String relative(String path) {
    final prefix = '$root${Platform.pathSeparator}';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  void emit(List<Diagnostic> group) {
    out.writeln();
    for (final d in group) {
      final message = d.correction == null
          ? d.message
          : '${d.message} ${d.correction}';
      out.writeln(
        '${d.severity.toLowerCase().padLeft(7)} - '
        '${relative(d.file)}:${d.line}:${d.column} - $message - ${d.code}',
      );
      for (final context in d.contextMessages) {
        final location = (context['location'] as Map).cast<String, Object?>();
        var text = context['message'] as String;
        while (text.endsWith('.')) {
          text = text.substring(0, text.length - 1);
        }
        out.writeln(
          '${' ' * 10} - $text at ${relative(location['file'] as String)}:'
          '${location['startLine']}:${location['startColumn']}.',
        );
      }
    }
    out.writeln();
  }

  if (first.isNotEmpty) {
    out.writeln();
    out.writeln(
      "Errors were found in 'pubspec.yaml' and/or 'analysis_options.yaml' "
      'which might result in either invalid diagnostics being produced or '
      'valid diagnostics being missed.',
    );
    emit(first);
    if (rest.isNotEmpty) out.writeln('Errors in remaining files.');
  }
  if (rest.isNotEmpty) emit(rest);
  final count = diagnostics.length;
  out.writeln('$count ${count == 1 ? 'issue' : 'issues'} found.');
  return out.toString();
}

int _byOrder(Diagnostic a, Diagnostic b) => a.compareTo(b);

/// Removes the overlays of [files] that [_applyFixes] left in [server]: the
/// server keeps them, and they would stand in for those files in later
/// requests.
Future<void> _dropOverlays(AnalysisServer server, Set<String> files) async {
  if (files.isEmpty || !server.running) return;
  await server.request('analysis.updateContent', {
    'files': {
      for (final file in files) file: {'type': 'remove'},
    },
  });
}

/// Fixes the project at [root] in place as `dart fix --apply` does, adding
/// the files it gives the server as overlays to [overlaid]. Returns the
/// server's reason when it computes no fixes, else null.
Future<String?> _applyFixes(
  AnalysisServer server,
  String root,
  Set<String> overlaid,
) async {
  final contents = <String, String>{};
  // What one bulk-fix request proposes, applied to [contents] and given back
  // to the server as overlays: the server's refusal, whether it proposed
  // edits, and whether it named any fixes.
  Future<(String, bool, bool)> pass({bool updatePubspec = false}) async {
    final result = await server.request('edit.bulkFixes', {
      'included': [canonical(root)],
      'inTestMode': false,
      'updatePubspec': updatePubspec,
    });
    final edits = (result['edits'] as List).cast<Map<String, Object?>>();
    final overlays = <String, Object?>{};
    for (final edit in edits) {
      final file = edit['file'] as String;
      var content = contents.putIfAbsent(file, () {
        final existing = File(file);
        return existing.existsSync() ? existing.readAsStringSync() : '';
      });
      // In the order given, which is end to start, as `dart fix` applies
      // them.
      for (final e in (edit['edits'] as List).cast<Map<String, Object?>>()) {
        final offset = e['offset'] as int;
        content = content.replaceRange(
          offset,
          offset + (e['length'] as int),
          e['replacement'] as String,
        );
      }
      contents[file] = content;
      overlays[file] = {'type': 'add', 'content': content};
    }
    overlaid.addAll(overlays.keys);
    await server.request('analysis.updateContent', {'files': overlays});
    final details = (result['details'] as List?) ?? const [];
    return (
      result['message'] as String? ?? '',
      edits.isNotEmpty,
      details.isNotEmpty,
    );
  }

  // `dart fix --apply`'s loop: passes until one proposes nothing, at most
  // [_maxPasses], then one for the pubspec if anything was fixed.
  var fixed = false;
  var edited = false;
  var passes = 0;
  do {
    final (message, edits, details) = await pass();
    if (message.isNotEmpty) return message;
    fixed |= details;
    edited = edits;
    passes++;
  } while (passes < _maxPasses && edited);
  if (!edited && fixed) await pass(updatePubspec: true);
  contents.forEach((file, content) => File(file).writeAsStringSync(content));
  return null;
}

/// Bulk-fix passes before giving up on fixes that keep producing more, as
/// `dart fix` limits them.
const _maxPasses = 4;
