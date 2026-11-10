import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Fails if any `pubspec.yaml` or `pubspec.lock` exists in this workspace.
void main(List<String> args) {
  final module = File(Runfiles.create().rlocation(args.single))
      .resolveSymbolicLinksSync();
  final root = Directory(File(module).parent.path);
  final found = <String>[];
  void walk(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entity is Directory) {
        // Bazel's convenience symlinks are links, which listSync reports as
        // links; `.bazel_env` and the like are not this workspace's sources.
        if (!name.startsWith('.')) walk(entity);
      } else if (name == 'pubspec.yaml' || name == 'pubspec.lock') {
        found.add(entity.path);
      }
    }
  }

  walk(root);
  if (found.isNotEmpty) {
    stderr.writeln(
      'This workspace must have no pubspec:\n  ${found.join('\n  ')}',
    );
    exitCode = 1;
  } else {
    stdout.writeln('PASS: no pubspec under ${root.path}');
  }
}
