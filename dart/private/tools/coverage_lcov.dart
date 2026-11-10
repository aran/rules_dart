import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';

// Shared by `coverage_converter` and `coverage_collector`: where a script of a
// Dart program is in the workspace, and the LCOV tracefile of the lines it ran.

/// Writes [content] to [path] whole, under another name first: Bazel's
/// coverage runner merges every `*.dat` in `COVERAGE_DIR`.
void writeTracefile(String path, String content) {
  final partial = File('$path.partial')..writeAsStringSync(content);
  partial.renameSync(path);
}

/// Where each script of a test's program is in the workspace.
class CoverageSources {
  CoverageSources({
    required Iterable<String> instrumented,
    required this.packages,
  }) {
    for (final line in instrumented) {
      final path = line.trim();
      if (path.isEmpty) continue;
      _byRootPath[_rootPath(path)] = path;
    }
  }

  /// Each package's `lib/` directories, by path below the kernel roots.
  final Map<String, List<String>> packages;

  /// Instrumented files by path below the kernel roots: a generated file's
  /// path with its output directory taken off.
  final _byRootPath = <String, String>{};

  static final _outputDirectory = RegExp(r'^bazel-out/[^/]+/bin/');

  static String _rootPath(String execPath) =>
      execPath.replaceFirst(_outputDirectory, '');

  /// The instrumented file [script] (a VM script URI) names, by its path from
  /// the exec root, or `null` when it names none.
  String? pathOf(String script) {
    final uri = Uri.parse(script);
    switch (uri.scheme) {
      case 'org-dartlang-root':
        return _byRootPath[uri.path.substring(1)];
      case 'package':
        final slash = uri.path.indexOf('/');
        if (slash < 0) return null;
        final name = uri.path.substring(0, slash);
        final rest = uri.path.substring(slash + 1);
        for (final lib in packages[name] ?? const <String>[]) {
          if (_byRootPath['$lib$rest'] case final path?) return path;
        }
    }
    return null;
  }
}

/// [hits] as an LCOV tracefile of the scripts [sources] places, in path
/// order, lines ascending.
String lcov(Map<String, HitMap> hits, CoverageSources sources) {
  final byPath = <String, Map<int, int>>{};
  for (final MapEntry(key: script, value: hitMap) in hits.entries) {
    final path = sources.pathOf(script);
    if (path == null) continue;
    final lines = byPath.putIfAbsent(path, () => {});
    for (final MapEntry(key: line, value: count) in hitMap.lineHits.entries) {
      lines[line] = (lines[line] ?? 0) + count;
    }
  }
  final out = StringBuffer();
  for (final path in byPath.keys.toList()..sort()) {
    final lines = byPath[path]!;
    out.writeln('SF:$path');
    for (final line in lines.keys.toList()..sort()) {
      out.writeln('DA:$line,${lines[line]}');
    }
    out
      ..writeln('LH:${lines.values.where((c) => c > 0).length}')
      ..writeln('LF:${lines.length}')
      ..writeln('end_of_record');
  }
  return out.toString();
}

/// The packages' `lib/` directories in the file [path], which
/// `test_coverage` (`dart/private/dart_coverage.bzl`) writes.
Map<String, List<String>> readPackages(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map;
  return {
    for (final MapEntry(:key, :value) in (json['packages'] as Map).entries)
      key as String: (value as List).cast<String>(),
  };
}
