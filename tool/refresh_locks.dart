/// Discovers all Bazel workspaces and refreshes their MODULE.bazel.lock files.
///
/// Usage: dart run tool/refresh_locks.dart
///
/// Finds every directory containing a MODULE.bazel (excluding references/)
/// and runs `bazel build --nobuild --lockfile_mode=update` in each to refresh
/// the lock file without reformatting MODULE.bazel (which `bazel mod tidy` does).
/// Uses only dart:io — no pubspec needed.
library;

import 'dart:io';

Future<void> main() async {
  final root = _findRepoRoot();
  final workspaces = _findWorkspaces(root);

  stdout.writeln('Found ${workspaces.length} workspaces:');
  for (final ws in workspaces) {
    stdout.writeln('  ${_relativePath(root, ws)}');
  }
  stdout.writeln('');

  var passed = 0;
  var failed = 0;

  for (final ws in workspaces) {
    final rel = _relativePath(root, ws);
    stdout.write('Refreshing $rel ... ');

    final result = await Process.run(
      'bazel',
      ['build', '--nobuild', '--lockfile_mode=update', '//...'],
      workingDirectory: ws,
    );

    if (result.exitCode == 0) {
      stdout.writeln('ok');
      passed++;
    } else {
      stdout.writeln('FAILED (exit ${result.exitCode})');
      stderr.writeln(result.stderr);
      failed++;
    }
  }

  stdout.writeln('');
  stdout.writeln('Done: $passed passed, $failed failed.');
  if (failed > 0) exit(1);
}

/// Walk up from the script's location to find the repo root (directory
/// containing MODULE.bazel at the top level).
String _findRepoRoot() {
  // Start from the directory containing this script, or fall back to cwd.
  var dir = Directory(Platform.script.toFilePath()).parent;

  // The script lives in tool/, so the repo root is one level up.
  // But also handle being run from the repo root via `dart run tool/...`.
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/dart').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }

  // Fall back to cwd.
  return Directory.current.path;
}

/// Find all directories containing MODULE.bazel, excluding references/.
List<String> _findWorkspaces(String root) {
  final workspaces = <String>[];

  void scan(Directory dir) {
    if (dir.path.contains('/references/')) return;
    if (dir.path.contains('/.git')) return;
    if (dir.path.contains('/bazel-')) return;

    if (File('${dir.path}/MODULE.bazel').existsSync()) {
      workspaces.add(dir.path);
    }

    for (final entity in dir.listSync()) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        // Skip hidden dirs and bazel output dirs.
        if (name.startsWith('.') || name.startsWith('bazel-')) continue;
        if (name == 'references') continue;
        scan(entity);
      }
    }
  }

  scan(Directory(root));

  // Sort: root first, then alphabetically.
  workspaces.sort((a, b) {
    if (a == root) return -1;
    if (b == root) return 1;
    return a.compareTo(b);
  });

  return workspaces;
}

String _relativePath(String root, String path) {
  if (path == root) return '.';
  if (path.startsWith('$root/')) return path.substring(root.length + 1);
  return path;
}
