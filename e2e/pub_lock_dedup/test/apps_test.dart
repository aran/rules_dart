import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs each app, given by its runfiles path, and fails unless it prints every
/// line its packages, built once from several locks, must produce.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final expected = <String, List<String>>{
    'two_hubs': ['First even: 2', 'Multi-lock dedup test passed!'],
    'cross_module': [
      'First > 4: 5',
      'cross_module',
      'Cross-module test passed!',
    ],
  };
  final problems = <String>[];
  for (final app in args) {
    final fixture = expected.keys.firstWhere(
      (name) => app.contains('/$name/'),
      orElse: () => throw ArgumentError('no expectation for $app'),
    );
    final result = Process.runSync(runfiles.rlocation(app), const []);
    final lines = (result.stdout as String).split(RegExp(r'\r?\n'));
    if (result.exitCode != 0) {
      problems.add('$app exited ${result.exitCode}: ${result.stderr}');
    }
    for (final line in expected[fixture]!) {
      if (!lines.contains(line)) problems.add('$app did not print "$line"');
    }
  }
  if (args.length != expected.length) {
    problems.add('expected ${expected.length} apps, got ${args.length}');
  }
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('PASS: ${args.length} apps');
  }
}
