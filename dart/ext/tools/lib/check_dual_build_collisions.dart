/// Scans for `build_runner`-style generated Dart files that have been
/// committed to the source tree and would collide with `rules_dart`'s
/// codegen outputs.
///
/// Flags every file ending in an extension `baseline_generated_extensions.txt`
/// lists. The Gazelle plugin filters the same extensions out of the sources
/// it generates rules for, from a copy of the list of its own.
///
/// Usage: `bazel run @rules_dart//dart/ext/tools:check_dual_build_collisions -- path/to/repo`

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

/// Loads the baseline extension list from [rlocationPath], its runfiles path
/// (the binary's first argument, from `$(rlocationpath)`, so that it resolves
/// in whichever module runs the tool).
List<String> loadBaselineExtensions(String rlocationPath) =>
    _parse(File(Runfiles.create().rlocation(rlocationPath)).readAsStringSync());

List<String> _parse(String raw) {
  return [
    for (final line in raw.split('\n'))
      if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
  ];
}

/// [args] is the extension list's runfiles path, then the directory to scan,
/// relative to the directory `bazel run` was started in (that directory when
/// absent).
Future<int> runCli(List<String> args) async {
  final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
  final target = args.length < 2 ? '.' : args[1];
  final root = Directory(
    cwd == null || File(target).isAbsolute ? target : '$cwd/$target',
  );
  if (!root.existsSync()) {
    stderr.writeln('error: ${root.path} is not a directory');
    return 2;
  }
  final extensions = loadBaselineExtensions(args.first);
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
