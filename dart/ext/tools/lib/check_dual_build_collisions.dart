/// Scans for `build_runner`-style generated Dart files that have been
/// committed to the source tree and would collide with `rules_dart`'s
/// codegen outputs.
///
/// Keeps the extension list in sync with Gazelle's filter — both load
/// `baseline_generated_extensions.txt` from
/// `@rules_dart//gazelle/dart`. The Gazelle filter uses it as baseline
/// additions to `allRegisteredProducedExtensions()`; this tool uses it as
/// the full catalog of generated-file suffixes to flag.
///
/// Usage (standalone): `dart run check_dual_build_collisions.dart [root]`
/// Usage (Bazel): `bazel run @rules_dart//dart/ext/tools:check_dual_build_collisions -- path/to/repo`

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Result of a single scan. [collisions] is the absolute paths of files
/// whose basename ends with a tracked generated-file extension.
class CollisionReport {
  CollisionReport(this.collisions);
  final List<String> collisions;
  bool get isEmpty => collisions.isEmpty;
}

/// Walks [root] and returns all files whose name ends with any of
/// [extensions]. Skips `bazel-*`, `.git`, `.dart_tool`, `build` subtrees —
/// matching the shell-script semantics.
CollisionReport checkDualBuildCollisions(
  Directory root,
  List<String> extensions,
) {
  if (!root.existsSync()) {
    throw ArgumentError('Directory does not exist: ${root.path}');
  }
  final hits = <String>[];
  final rootPath = root.absolute.path;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    // Only match prune segments *inside* the scanned root. A scan of
    // `/home/user/build/my-proj` must not be skipped just because a
    // path component named `build` exists in the user's parent
    // directory chain.
    final abs = entity.absolute.path;
    final rel = abs.startsWith(rootPath + Platform.pathSeparator)
        ? abs.substring(rootPath.length + 1)
        : abs;
    if (_isPruned(rel)) continue;
    for (final ext in extensions) {
      if (abs.endsWith(ext)) {
        hits.add(abs);
        break;
      }
    }
  }
  hits.sort();
  return CollisionReport(hits);
}

// Prunes subtrees matched by segment, not substring. A path like
// `/home/user/build/my-proj/lib/foo.dart` must NOT be pruned just because
// it has a `build` component somewhere in its ancestry; only an actual
// `build/` directory inside the scanned root should be.
bool _isPruned(String path) {
  const prunedSegments = {'.git', '.dart_tool', 'build'};
  for (final segment in path.split(Platform.pathSeparator)) {
    if (prunedSegments.contains(segment)) return true;
    if (segment.startsWith('bazel-')) return true;
  }
  return false;
}

/// Loads the baseline extension list. In Bazel runs the file is in
/// runfiles; for direct `dart run` invocations it falls back to looking up
/// `gazelle/dart/baseline_generated_extensions.txt` relative to the CWD.
List<String> loadBaselineExtensions() {
  try {
    final r = Runfiles.create();
    final path = r.rlocation(
      '_main/gazelle/dart/baseline_generated_extensions.txt',
    );
    return _parse(File(path).readAsStringSync());
  } catch (_) {
    final f = File('gazelle/dart/baseline_generated_extensions.txt');
    if (f.existsSync()) return _parse(f.readAsStringSync());
    rethrow;
  }
}

List<String> _parse(String raw) {
  return [
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
  ];
}

Future<int> runCli(List<String> args) async {
  final root = Directory(args.isEmpty ? '.' : args.first);
  if (!root.existsSync()) {
    stderr.writeln('error: ${root.path} is not a directory');
    return 2;
  }
  final extensions = loadBaselineExtensions();
  final report = checkDualBuildCollisions(root, extensions);
  if (report.isEmpty) {
    print('no generated-file collisions found under ${root.path}');
    return 0;
  }
  final count = report.collisions.length;
  print(
    'found $count source-tree generated file(s) that would collide with Bazel codegen outputs:',
  );
  for (final p in report.collisions) {
    print(p);
  }
  print('');
  print('to resolve:');
  print('  1. remove these files from the source tree (`git rm` each one)');
  print(
    '  2. add matching patterns to `.gitignore` so `build_runner` output stops',
  );
  print('     being committed during the migration:');
  for (final ext in extensions) {
    print('       **/*$ext');
  }
  print('');
  print(
    'see docs/ext.md (Dual-build coexistence) for the full catalog of collision modes.',
  );
  return 1;
}

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
