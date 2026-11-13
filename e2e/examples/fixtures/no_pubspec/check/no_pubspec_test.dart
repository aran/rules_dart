import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Fails if a `pubspec.yaml` or `pubspec.lock` is in this fixture, or in any
/// directory above it up to the workspace root: where a tool walking up from
/// one of the fixture's files would find it.
void main(List<String> args) {
  final build = File(Runfiles.create().rlocation(args.single))
      .resolveSymbolicLinksSync();
  final fixture = File(build).parent;
  final found = <String>[];
  bool isPubspec(String name) =>
      name == 'pubspec.yaml' || name == 'pubspec.lock';
  String nameOf(FileSystemEntity entity) =>
      entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  void walk(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = nameOf(entity);
      if (entity is Directory) {
        // Bazel's convenience symlinks are links, which listSync reports as
        // links; `.bazel_env` and the like are not this fixture's sources.
        if (!name.startsWith('.')) walk(entity);
      } else if (isPubspec(name)) {
        found.add(entity.path);
      }
    }
  }

  walk(fixture);
  var dir = fixture;
  while (true) {
    dir = dir.parent;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory && isPubspec(nameOf(entity))) {
        found.add(entity.path);
      }
    }
    if (File('${dir.path}/MODULE.bazel').existsSync()) break;
    if (dir.parent.path == dir.path) {
      stderr.writeln('No MODULE.bazel above ${fixture.path}');
      exitCode = 1;
      return;
    }
  }
  if (found.isNotEmpty) {
    stderr.writeln(
      'This fixture must have no pubspec, nor any directory above it:\n'
      '  ${found.join('\n  ')}',
    );
    exitCode = 1;
  } else {
    stdout.writeln('PASS: no pubspec under ${fixture.path} or above it');
  }
}
