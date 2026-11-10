// The report `dart analyze` prints (no terminal: no colour, no wrapping),
// naming each staged file by the workspace path it was copied from.
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

/// A context message of a [Reported] diagnostic.
class Context {
  Context(this.text, this.file, this.line, this.column);
  final String text, file;
  final int line, column;
}

/// One diagnostic as `dart analyze` keeps it.
class Reported {
  Reported({
    required this.severity,
    required this.code,
    required this.file,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
    required this.message,
    required this.correction,
    required this.context,
  });

  final DiagnosticSeverity severity;
  final String code, file, message;
  final String? correction;
  final int offset, length, line, column;
  final List<Context> context;

  int get _level => switch (severity) {
    DiagnosticSeverity.ERROR => 0,
    DiagnosticSeverity.WARNING => 1,
    _ => 2,
  };
}

int _compare(Reported a, Reported b) {
  final d = a._level - b._level;
  if (d != 0) return d;
  if (a.file != b.file) return a.file.compareTo(b.file);
  if (a.offset != b.offset) return a.offset - b.offset;
  return a.message.compareTo(b.message);
}

/// [path] as the user knows it: relative to [src] (the staged copy of the
/// workspace) when inside it, else as given.
String workspacePath(String path, String src) =>
    p.isWithin(src, path) ? p.relative(path, from: src) : path;

/// Writes [all] to [out] as `dart analyze` does; returns its exit code.
int report(
  StringBuffer out,
  List<Reported> all,
  String src, {
  required bool fatalInfos,
}) {
  if (all.isEmpty) return 0;
  final priority = <Reported>[], rest = <Reported>[];
  for (final e in all) {
    final isPriority = const {
      'analysis_options.yaml',
      'pubspec.yaml',
    }.contains(p.basename(e.file));
    (isPriority && e.severity == DiagnosticSeverity.ERROR ? priority : rest)
        .add(e);
  }
  priority.sort(_compare);
  rest.sort(_compare);
  void emit(List<Reported> errors) {
    out.writeln('');
    for (final e in errors) {
      final severity = e.severity.name.toLowerCase().padLeft(7);
      var message = e.message;
      if (e.correction != null) message += ' ${e.correction}';
      out.writeln(
        '$severity - ${workspacePath(e.file, src)}:${e.line}:${e.column} - '
        '$message - ${e.code}',
      );
      for (final c in e.context) {
        final text = c.text.endsWith('.')
            ? c.text.substring(0, c.text.length - 1)
            : c.text;
        out.writeln(
          '${' ' * 10} - $text at ${workspacePath(c.file, src)}:'
          '${c.line}:${c.column}.',
        );
      }
    }
    out.writeln('');
  }

  if (priority.isNotEmpty) {
    out.writeln('');
    out.writeln(
      "Errors were found in 'pubspec.yaml' and/or "
      "'analysis_options.yaml' which might result in either invalid "
      'diagnostics being produced or valid diagnostics being missed.',
    );
    emit(priority);
    if (rest.isNotEmpty) out.writeln('Errors in remaining files.');
  }
  if (rest.isNotEmpty) emit(rest);
  final n = all.length;
  out.writeln('$n ${n == 1 ? 'issue' : 'issues'} found.');
  if (all.any((e) => e._level == 0)) return 3;
  if (all.any((e) => e._level == 1)) return 2;
  if (fatalInfos && all.any((e) => e._level == 2)) return 1;
  return 0;
}

/// [text] with the staged copy's absolute paths, which messages quote,
/// rewritten to workspace paths.
String unstage(String text, String src) =>
    text.replaceAll('$src${p.separator}', '').replaceAll('$src/', '');
