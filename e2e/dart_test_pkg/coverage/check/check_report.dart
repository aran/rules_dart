import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Checks the LCOV report `bazel coverage --combined_report=lcov` wrote for
/// `//coverage/...` (its path is the one argument) against the fixture's
/// sources: each line marked `// covered` has hits and each marked
/// `// uncovered` has none, no line a `// coverage:ignore-line` or an
/// `ignore-start`/`ignore-end` pair names is reported, a file marked
/// `// coverage:ignore-file` has no line reported, and nothing else is.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: check_report <lcov report>');
    exit(2);
  }
  final report = _parse(File(args.single).readAsLinesSync());
  final runfiles = Runfiles.create();
  final sources = {
    'coverage/lib/shapes.dart': '_main/coverage/lib/shapes.dart',
    'coverage/units/lib/units.dart': '_main/coverage/units/lib/units.dart',
  };
  // Carried by the tests, and left without a line in the report: Bazel
  // lists every instrumented file, the lines it has apart.
  const ignoredFile = 'coverage/excluded/lib/excluded.dart';
  final ignoredFileLines = File(runfiles.rlocation('_main/$ignoredFile'))
      .readAsLinesSync();
  final problems = <String>[];
  if (!ignoredFileLines.any((l) => l.contains('coverage:ignore-file'))) {
    problems.add('$ignoredFile does not mark itself coverage:ignore-file');
  }
  if (report[ignoredFile]?.isNotEmpty ?? false) {
    problems.add('$ignoredFile is ignored but has ${report[ignoredFile]}');
  }
  if (!_sameKeys(report.keys.where((k) => k != ignoredFile), sources.keys)) {
    problems.add(
      'the report covers ${report.keys.toList()..sort()}, '
      'not ${sources.keys.toList()..sort()}',
    );
  }
  for (final MapEntry(key: path, value: rlocation) in sources.entries) {
    final lines = File(runfiles.rlocation(rlocation)).readAsLinesSync();
    final hits = report[path] ?? const {};
    final ignored = _ignoredLines(lines);
    if (ignored.isEmpty && path == 'coverage/lib/shapes.dart') {
      problems.add('$path has no ignored line to check');
    }
    for (final line in ignored) {
      if (hits.containsKey(line)) {
        problems.add('$path:$line is ignored but reported: ${lines[line - 1]}');
      }
    }
    for (var i = 0; i < lines.length; i++) {
      final line = i + 1;
      final count = hits[line];
      if (lines[i].endsWith('// covered') && (count == null || count == 0)) {
        problems.add('$path:$line is not covered: ${lines[i].trim()}');
      }
      if (lines[i].endsWith('// uncovered') && count != 0) {
        final found = count ?? 'no entry';
        problems.add('$path:$line should be reported uncovered, has $found');
      }
    }
  }
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exit(1);
  }
  stdout.writeln('coverage report matches the fixture');
}

/// The lines a `coverage:ignore-line` or an `ignore-start`/`ignore-end` pair
/// names, the markers included.
Set<int> _ignoredLines(List<String> lines) {
  final ignored = <int>{};
  int? start;
  for (var i = 0; i < lines.length; i++) {
    final line = i + 1;
    if (lines[i].contains('coverage:ignore-line')) ignored.add(line);
    if (lines[i].contains('coverage:ignore-start')) start = line;
    if (start != null) ignored.add(line);
    if (lines[i].contains('coverage:ignore-end')) start = null;
  }
  return ignored;
}

/// Hits by line, by source file.
Map<String, Map<int, int>> _parse(List<String> lcov) {
  final report = <String, Map<int, int>>{};
  Map<int, int>? current;
  for (final line in lcov) {
    if (line.startsWith('SF:')) {
      current = report.putIfAbsent(line.substring(3), () => {});
    } else if (line.startsWith('DA:') && current != null) {
      final [number, count, ...] = line.substring(3).split(',');
      current[int.parse(number)] = int.parse(count);
    } else if (line == 'end_of_record') {
      current = null;
    }
  }
  return report;
}

bool _sameKeys(Iterable<String> a, Iterable<String> b) =>
    a.toSet().length == b.toSet().length && a.toSet().containsAll(b);
