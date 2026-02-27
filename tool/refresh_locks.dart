/// Refreshes all lock files in the repository.
///
/// Usage: dart run tool/refresh_locks.dart
///
/// 1. Finds every directory containing a MODULE.bazel (excluding references/)
///    and runs `bazel mod tidy --lockfile_mode=refresh` in each, followed by
///    `bazel build --nobuild --lockfile_mode=update //...` to capture any
///    transitive module extension entries that `mod tidy` misses. This keeps
///    MODULE.bazel formatting canonical and lock files complete.
///
/// 2. Finds every directory containing a pubspec.yaml (excluding references/,
///    dev/testdata/, and e2e/) and runs `dart pub get` to refresh the
///    pubspec.lock file.
///
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

    // Step 1: bazel mod tidy --lockfile_mode=refresh
    // Formats MODULE.bazel and refreshes the lock file from the registry.
    final tidy = await Process.run(
      'bazel',
      ['mod', 'tidy', '--lockfile_mode=refresh'],
      workingDirectory: ws,
    );

    if (tidy.exitCode != 0) {
      stdout.writeln('FAILED at mod tidy (exit ${tidy.exitCode})');
      stderr.writeln(tidy.stderr);
      failed++;
      continue;
    }

    // Step 2: bazel build --nobuild --lockfile_mode=update //...
    // Captures transitive module extension entries that mod tidy misses.
    final build = await Process.run(
      'bazel',
      ['build', '--nobuild', '--lockfile_mode=update', '//...'],
      workingDirectory: ws,
    );

    if (build.exitCode == 0) {
      stdout.writeln('ok');
      passed++;
    } else {
      stdout.writeln('FAILED at build (exit ${build.exitCode})');
      stderr.writeln(build.stderr);
      failed++;
    }
  }

  // --- Phase 2: pubspec.lock files ---
  final pubPackages = _findPubPackages(root);

  if (pubPackages.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Found ${pubPackages.length} Dart packages:');
    for (final pkg in pubPackages) {
      stdout.writeln('  ${_relativePath(root, pkg)}');
    }
    stdout.writeln('');

    for (final pkg in pubPackages) {
      final rel = _relativePath(root, pkg);
      stdout.write('Refreshing $rel pubspec.lock ... ');

      final result = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: pkg,
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

/// Find all directories containing pubspec.yaml, excluding references/,
/// dev/testdata/, and e2e/.
List<String> _findPubPackages(String root) {
  final packages = <String>[];

  void scan(Directory dir) {
    if (dir.path.contains('/references/')) return;
    if (dir.path.contains('/dev/testdata/')) return;
    if (dir.path.contains('/e2e/')) return;
    if (dir.path.contains('/.git')) return;
    if (dir.path.contains('/bazel-')) return;
    if (dir.path.contains('/.dart_tool')) return;

    if (File('${dir.path}/pubspec.yaml').existsSync()) {
      packages.add(dir.path);
    }

    for (final entity in dir.listSync()) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        if (name.startsWith('.') || name.startsWith('bazel-')) continue;
        if (name == 'references') continue;
        scan(entity);
      }
    }
  }

  scan(Directory(root));
  packages.sort();
  return packages;
}

String _relativePath(String root, String path) {
  if (path == root) return '.';
  if (path.startsWith('$root/')) return path.substring(root.length + 1);
  return path;
}
