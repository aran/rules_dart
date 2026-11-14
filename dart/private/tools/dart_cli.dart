// `Analyzer` by running `dart analyze` and `dart fix` themselves.
import 'dart:io';

import 'analyzer.dart';
import 'summary_analyzer/doc_imports.dart';

/// Runs the SDK's `dart analyze` and `dart fix --apply`.
class DartCli implements Analyzer {
  /// Runs them caching in [cache], which is emptied first and removed when
  /// a command ends.
  DartCli({required String cache}) : _cache = Directory(cache);

  final Directory _cache;

  @override
  Future<Output> analyze(
    String dart,
    String project, {
    required bool fatalInfos,
  }) async => _withoutUnresolvedDocImports(
    await _run(dart, [
      'analyze',
      if (fatalInfos) '--fatal-infos',
      '--cache=${_cache.absolute.path}',
      project,
    ]),
    project,
    fatalInfos: fatalInfos,
  );

  // `dart fix` has no `--cache`: its server caches under the home directory,
  // so the home is the cache.
  @override
  Future<Output> fix(String dart, String root) => _run(
    dart,
    ['fix', '--apply', root],
    environment: {
      Platform.isWindows ? 'LOCALAPPDATA' : 'HOME': _cache.absolute.path,
    },
  );

  Future<Output> _run(
    String dart,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (_cache.existsSync()) _cache.deleteSync(recursive: true);
    _cache.createSync(recursive: true);
    try {
      final result = await Process.run(dart, args, environment: environment);
      return (
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } finally {
      try {
        _cache.deleteSync(recursive: true);
      } on FileSystemException {
        // A file the server held open on Windows: the next run clears it.
      }
    }
  }
}

/// A diagnostic of `dart analyze`'s report: its severity, its file relative to
/// the project, its line and column, its message, and its code.
final _diagnosticLine = RegExp(
  r'^\s*(error|warning|info) - (.+?):(\d+):(\d+) - (.*) - (\S+)$',
);

/// A context message under a diagnostic.
final _contextLine = RegExp(r'^\s+- ');

final _countLine = RegExp(r'^\d+ issues? found\.$');

/// [output] of `dart analyze` over [project] as if it had not found what
/// `withoutUnresolvedDocImports` leaves out, its count and exit code included.
Output _withoutUnresolvedDocImports(
  Output output,
  String project, {
  required bool fatalInfos,
}) {
  final lines = output.stdout.split('\n');
  final found =
      <
        ({
          int start,
          int end,
          String severity,
          String file,
          int line,
          int column,
          String message,
          String code,
        })
      >[];
  for (var i = 0; i < lines.length; i++) {
    final match = _diagnosticLine.firstMatch(lines[i]);
    if (match == null) continue;
    var end = i + 1;
    while (end < lines.length && _contextLine.hasMatch(lines[end])) {
      end++;
    }
    found.add((
      start: i,
      end: end,
      severity: match[1]!,
      file: '$project/${match[2]!}',
      line: int.parse(match[3]!),
      column: int.parse(match[4]!),
      message: match[5]!,
      code: match[6]!,
    ));
  }
  final kept = withoutUnresolvedDocImports(
    found,
    project: project,
    code: (d) => d.code,
    file: (d) => d.file,
    message: (d) => d.message,
    line: (d) => d.line,
    column: (d) => d.column,
  );
  if (kept.length == found.length) return output;

  if (kept.isEmpty) {
    final before = lines.take(found.first.start).toList();
    while (before.isNotEmpty && before.last.trim().isEmpty) {
      before.removeLast();
    }
    return (
      exitCode: 0,
      stdout: [...before, 'No issues found!', ''].join('\n'),
      stderr: output.stderr,
    );
  }
  final dropped = {
    for (final d in found)
      if (!kept.contains(d))
        for (var i = d.start; i < d.end; i++) i,
  };
  final count = kept.length;
  final severities = {for (final d in kept) d.severity};
  return (
    exitCode: severities.contains('error')
        ? 3
        : severities.contains('warning')
        ? 2
        : fatalInfos
        ? 1
        : 0,
    stdout: [
      for (var i = 0; i < lines.length; i++)
        if (!dropped.contains(i))
          _countLine.hasMatch(lines[i])
              ? '$count ${count == 1 ? 'issue' : 'issues'} found.'
              : lines[i],
    ].join('\n'),
    stderr: output.stderr,
  );
}
