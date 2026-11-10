import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';

// Shared by `coverage_converter` and `coverage_collector`: where a script of a
// Dart program is in the workspace, and the LCOV tracefile of the lines it ran
// that its source does not exclude with `// coverage:ignore-line`,
// `ignore-start`/`ignore-end` or `ignore-file`, as `dart test --coverage-path`
// leaves them out.

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
    required this.files,
    required this.locate,
  }) {
    for (final line in instrumented) {
      final path = line.trim();
      if (path.isEmpty) continue;
      _byRootPath[_rootPath(path)] = path;
    }
  }

  /// Each package's `lib/` directories, by path below the kernel roots.
  final Map<String, List<String>> packages;

  /// The runfiles path of each source the test carries, by its path from the
  /// exec root: the files Bazel may instrument, which the ignore comments in
  /// them are read from.
  final Map<String, String> files;

  /// The path on disk of a runfile, given its runfiles path.
  final String Function(String runfilesPath) locate;

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

/// Resolves a script to its source in the runfiles, for the ignore comments
/// `package:coverage` reads from it.
class _SourceResolver extends Resolver {
  // ignore: deprecated_member_use
  _SourceResolver(this._sources) : super();

  final CoverageSources _sources;

  /// A script [sources] does not place is not reported, so has nothing to
  /// read; one it places whose source is not in the runfiles is an error, not
  /// a report that quietly ignores nothing.
  @override
  String? resolve(String scriptUri) {
    final path = _sources.pathOf(scriptUri);
    if (path == null) return null;
    final runfile = _sources.files[path];
    if (runfile == null) {
      throw StateError(
        '$scriptUri is $path, which Bazel instruments, but the test carries '
        'no copy to read its coverage:ignore comments from',
      );
    }
    final located = _sources.locate(runfile);
    if (!File(located).existsSync()) {
      throw StateError('$path is not in the runfiles at $runfile');
    }
    return located;
  }
}

/// [hits] as an LCOV tracefile of the scripts [sources] places, in path
/// order, lines ascending, without the lines and files their sources ignore.
String lcov(Map<String, HitMap> hits, CoverageSources sources) {
  hits = hits.filterIgnored(
    ignoredLinesInFilesCache: {},
    resolver: _SourceResolver(sources),
  );
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

/// The packages' `lib/` directories and the runfiles path of each source, in
/// the file [path], which `test_coverage` (`dart/private/dart_coverage.bzl`)
/// writes.
({Map<String, List<String>> packages, Map<String, String> files})
readSourcesFile(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map;
  return (
    packages: {
      for (final MapEntry(:key, :value) in (json['packages'] as Map).entries)
        key as String: (value as List).cast<String>(),
    },
    files: (json['files'] as Map).cast<String, String>(),
  );
}
