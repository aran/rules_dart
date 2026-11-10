// Checks, or with `--refresh` rewrites, the pubspec.lock of every tracked Dart
// package in the checkout, with the pinned Dart SDK.
//
//   bazel run //tool:pub_locks               check: `dart pub get --enforce-lockfile`
//   bazel run //tool:pub_locks -- --refresh  rewrite: `dart pub get`
//
// The packages under e2e/ and dev/testdata/ are left alone: their locks are
// fixtures that the e2e workspaces read as they are. MODULE.bazel.lock files
// are `bazel run @overhead//locks:check`'s.
import 'dart:io';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  final refresh = args.length == 1 && args.single == '--refresh';
  if (args.isNotEmpty && !refresh) {
    stderr.writeln('usage: pub_locks [--refresh]');
    exit(2);
  }
  final listing = await Process.run('git', [
    'ls-files',
    '-z',
  ], workingDirectory: _repo);
  if (listing.exitCode != 0) {
    stderr.writeln('pub_locks: git ls-files failed: ${listing.stderr}');
    exit(2);
  }
  final packages = [
    for (final path in (listing.stdout as String).split('\x00'))
      if ((path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml')) &&
          !path.startsWith('e2e/') &&
          !path.startsWith('dev/testdata/'))
        path == 'pubspec.yaml'
            ? '.'
            : path.substring(0, path.length - '/pubspec.yaml'.length),
  ]..sort();

  final failed = <String>[];
  for (final package in packages) {
    // The pinned SDK rather than the `dart` on PATH, which can be older than
    // a package's SDK floor.
    final result = await Process.run('bazel', [
      'run',
      '--noshow_progress',
      '--ui_event_filters=-info',
      '@rules_dart//dart/pub',
      '--',
      'get',
      '--directory=$package',
      if (!refresh) '--enforce-lockfile',
    ], workingDirectory: _repo);
    if (result.exitCode == 0) {
      stdout.writeln('ok     $package');
      continue;
    }
    failed.add(package);
    stderr.writeln('FAILED $package (exit ${result.exitCode})');
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
  }
  if (failed.isEmpty) {
    stdout.writeln('pub_locks: ${packages.length} package(s) ok');
    return;
  }
  if (!refresh) {
    stderr.writeln(
      'Rewrite them with `bazel run //tool:pub_locks -- --refresh`.',
    );
  }
  exit(1);
}
