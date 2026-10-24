// `Analyzer` by driving the analysis server directly, printing and fixing as
// `dart analyze` and `dart fix --apply` do (see `analysis_server.dart`).
import 'dart:io';

import 'analysis_server.dart';
import 'analyzer.dart';

/// Asks the SDK's analysis server for what `dart analyze` and `dart fix`
/// would, and stops it whether or not its shutdown finishes.
class ServerAnalyzer implements Analyzer {
  ServerAnalyzer(this._dart, {required String cache}) : _cache = cache;

  final String _dart;
  final String _cache;

  @override
  Future<Output> analyze(String project, {required bool fatalInfos}) async {
    final server = await AnalysisServer.start(
      _dart,
      command: 'analyze',
      cache: _cache,
    );
    try {
      await server.analyze(project);
    } finally {
      await server.stop();
    }
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

  @override
  Future<Output> fix(String root) async {
    // `dart fix` turns plugins off: they cannot bulk fix.
    final server = await AnalysisServer.start(
      _dart,
      command: 'fix',
      cache: _cache,
      plugins: false,
    );
    String? refusal;
    try {
      refusal = await _applyFixes(server, root);
    } finally {
      await server.stop();
    }
    return (
      exitCode: refusal == null ? 0 : 3,
      stdout: refusal == null ? '' : 'Unable to compute fixes: $refusal\n',
      stderr: server.log.toString(),
    );
  }
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

/// Fixes the project at [root] in place as `dart fix --apply` does. Returns
/// the server's reason when it computes no fixes, else null.
Future<String?> _applyFixes(AnalysisServer server, String root) async {
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
    final edits = (result['edits'] as List).cast<Map>();
    final overlays = <String, Object?>{};
    for (final edit in edits) {
      final file = edit['file'] as String;
      var content = contents.putIfAbsent(file, () {
        final existing = File(file);
        return existing.existsSync() ? existing.readAsStringSync() : '';
      });
      // In the order given, which is end to start, as `dart fix` applies
      // them.
      for (final e in (edit['edits'] as List).cast<Map>()) {
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
