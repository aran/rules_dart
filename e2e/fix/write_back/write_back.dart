// Property: `bazel run @rules_dart//dart/fix` and `@rules_dart//dart/format`
// write into the workspace exactly what the `dart_analyze` aspect computed for
// the targets they are given: every target of one run, each file as its own
// target's check would have it, with `--dry-run` nothing, and a target a tag
// filter leaves out only with the flags that build it.
//
// The fixtures are this workspace's own sources, so each is put back
// afterwards, whatever happened.
//
// Run from the workspace: `bazel run //write_back`.
import 'dart:io';

/// Each fixture, and the file holding what the run must leave in it.
const _expected = {
  // Two targets fixed in one run: a library and a binary's entrypoint.
  'dirty/lib/model.dart': 'clean/lib/model.dart',
  'dirty_bin/main.dart': 'dirty_bin/golden/main.dart',
  // A 3.6 package, formatted in the short style.
  'short_style/lib/short.dart': 'short_style/golden/short.dart',
  // A target `.bazelrc` leaves out of the build, formatted once the run
  // passes the config that builds it.
  'deep/lib/deep.dart': 'deep/golden/deep.dart',
};

void main() {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln('run with `bazel run //write_back`');
    exit(2);
  }
  File file(String path) => File('$workspace/$path');

  final originals = {
    for (final path in _expected.keys) path: file(path).readAsStringSync(),
  };
  for (final MapEntry(key: path, value: golden) in _expected.entries) {
    if (originals[path] == file(golden).readAsStringSync()) {
      stderr.writeln('$path is already what the run would make it; restore it');
      exit(2);
    }
  }

  final failures = <String>[];
  void expectFiles(String when, Map<String, String> want) {
    for (final MapEntry(key: path, value: content) in want.entries) {
      if (file(path).readAsStringSync() != content) {
        failures.add('$when: $path is not as expected');
      }
    }
  }

  ProcessResult run(String tool, List<String> args, {bool fails = false}) {
    final result = Process.runSync('bazel', [
      'run',
      '@rules_dart//dart/$tool',
      '--',
      ...args,
    ], workingDirectory: workspace);
    if ((result.exitCode != 0) != fails) {
      failures.add(
        '$tool ${args.join(' ')} exited ${result.exitCode}:\n'
        '${result.stdout}${result.stderr}',
      );
    }
    return result;
  }

  try {
    final dry = run('fix', ['--dry-run', '//dirty:lib', '//dirty_bin:bin']);
    if (!'${dry.stdout}'.contains('--- a/dirty/lib/model.dart')) {
      failures.add('fix --dry-run printed no diff:\n${dry.stdout}');
    }
    expectFiles('after fix --dry-run', originals);

    // As `bazel build //deep:lib` builds nothing, so the run writes nothing,
    // and says why.
    final filtered = run('format', ['//deep:lib'], fails: true);
    if (!'${filtered.stderr}'.contains('left out every target')) {
      failures.add('format of a left-out target:\n${filtered.stderr}');
    }
    expectFiles('after format of a left-out target', originals);

    run('fix', ['//dirty:lib', '//dirty_bin:bin']);
    run('format', ['//short_style:lib']);
    run('format', ['--config=deep', '//deep:lib']);
    expectFiles('after fix and format', {
      for (final MapEntry(key: path, value: golden) in _expected.entries)
        path: file(golden).readAsStringSync(),
    });

    // What a fix wrote is what its target's analysis passes, so there is
    // nothing left to do.
    final again = run('fix', ['//dirty:lib', '//dirty_bin:bin']);
    if (!'${again.stdout}'.contains('0 files fixed.')) {
      failures.add('a second fix wrote again:\n${again.stdout}');
    }
  } finally {
    originals.forEach((path, content) => file(path).writeAsStringSync(content));
  }

  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
  stdout.writeln('write back: ok');
}
