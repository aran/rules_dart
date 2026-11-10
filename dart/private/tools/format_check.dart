// The verdict of the `dart_analyze` aspect's format check: fails when the
// target's format actions propose any change, naming the files and the command
// that writes those very changes.
//
// The verdict reads nothing but the changes files, so it and `bazel run
// @rules_dart//dart/format` cannot disagree.
import 'dart:io';

import 'changes.dart';

void main(List<String> args) {
  final changes = <String>[];
  String? stamp;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--changes':
        changes.add(args[++i]);
      case '--stamp':
        stamp = args[++i];
      default:
        stderr.writeln('format_check: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (changes.isEmpty || stamp == null) {
    stderr.writeln('format_check: --changes and --stamp are required');
    exit(64);
  }

  final sets = [for (final path in changes) ChangeSet.read(path)];
  final paths = [
    for (final set in sets)
      for (final change in set.changes) change.path,
  ]..sort();
  if (paths.isNotEmpty) {
    for (final path in paths) {
      stderr.writeln('Not formatted: $path');
    }
    stderr.writeln(
      'Format with `bazel run @rules_dart//dart/format -- ${sets.first.target}`.',
    );
    exit(1);
  }
  File(stamp).writeAsStringSync('formatted\n');
}
