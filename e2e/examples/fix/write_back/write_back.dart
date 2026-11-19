// Property: `bazel run @rules_dart//dart/fix` and `@rules_dart//dart/format`
// write into the workspace exactly what the `dart_analyze` aspect computed for
// the targets they are given: every target of one run, each file as its own
// target's check would have it, with `--dry-run` nothing, and a target a tag
// filter leaves out only with the flags that build it. And
// `@rules_dart//dart/unused_deps` removes from a BUILD file each written label
// that stands only for unused deps, at the call that wrote it, changes nothing
// else in the file, however it is formatted or spells the label, fails, naming
// the place, on one it cannot reach, and still fixes the other files when it
// cannot edit one.
//
// The fixtures are this workspace's own sources, so each is put back
// afterwards, whatever happened.
//
// Run from the workspace: `bazel run //fix/write_back`.
import 'dart:io';

/// Each fixture, and the file holding what the run must leave in it.
const _expected = {
  // Two targets fixed in one run: a library and a binary's entrypoint.
  'fix/dirty/lib/model.dart': 'fix/clean/lib/model.dart',
  'fix/dirty_bin/main.dart': 'fix/dirty_bin/golden/main.dart',
  // A 3.6 package, formatted in the short style.
  'fix/short_style/lib/short.dart': 'fix/short_style/golden/short.dart',
  // A target `.bazelrc` leaves out of the build, formatted once the run
  // passes the config that builds it.
  'fix/deep/lib/deep.dart': 'fix/deep/golden/deep.dart',
  // The unused deps of `//fix/unused:lib`, of the call `//fix/unused:call` and of
  // `//fix/unused:conformance_test` removed, and the `package:test` that test's
  // runner needs kept.
  'fix/unused/BUILD.bazel': 'fix/unused/golden/BUILD.golden',
};

/// A call of `fix/unused/BUILD.bazel` as buildifier writes it, and as it does
/// not. Nothing the fixer removes is in it.
const _tidy = 'alias(\n    name = "hub_a",\n    actual = ":leaf",\n)\n';
const _untidy = 'alias(name="hub_a",   actual=":leaf")\n';

/// Two packages whose BUILD files the fixer is given together, as they are
/// checked in and as the run writes them. buildifier shortens the first label
/// and joins the second, which the fixer then cannot find in the file.
const _spelled = 'fix/unused_spelled/BUILD.bazel';
const _spelledTidy = '"@path"';
const _spelledOtherwise = '"@path//:path"';
const _joined = 'fix/unused_joined/BUILD.bazel';
const _joinedTidy = '"//fix/unused_joined:leaf"';
const _joinedApart = '"//fix/unused_joined" + ":leaf"';

void main() {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln('run with `bazel run //fix/write_back`');
    exit(2);
  }
  File file(String path) => File('$workspace/$path');

  final originals = {
    for (final path in [..._expected.keys, _spelled, _joined])
      path: file(path).readAsStringSync(),
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
    final dry = run('fix', [
      '--dry-run',
      '//fix/dirty:lib',
      '//fix/dirty_bin:bin',
    ]);
    if (!'${dry.stdout}'.contains('--- a/fix/dirty/lib/model.dart')) {
      failures.add('fix --dry-run printed no diff:\n${dry.stdout}');
    }
    expectFiles('after fix --dry-run', originals);

    // As `bazel build //fix/deep:lib` builds nothing, so the run writes nothing,
    // and says why.
    final filtered = run('format', ['//fix/deep:lib'], fails: true);
    if (!'${filtered.stderr}'.contains('left out every target')) {
      failures.add('format of a left-out target:\n${filtered.stderr}');
    }
    expectFiles('after format of a left-out target', originals);

    final unusedDry = run('unused_deps', [
      '--dry-run',
      '//fix/unused:lib',
      '//fix/unused:call.program',
      '//fix/unused:conformance_test',
    ]);
    final removed = [
      for (final line in '${unusedDry.stdout}'.split('\n'))
        if (line.startsWith('-') && !line.startsWith('---'))
          line.substring(1).trim(),
    ];
    if (!'${unusedDry.stdout}'.contains('--- a/fix/unused/BUILD.bazel') ||
        !removed.contains('"@rules_dart//dart/runfiles",') ||
        !removed.contains('":leaf",') ||
        removed.any((l) => l.contains('test_pub_deps'))) {
      failures.add('unused_deps --dry-run printed:\n${unusedDry.stdout}');
    }
    expectFiles('after unused_deps --dry-run', originals);

    // `leaf` is in a list variable, and in a call a comprehension makes,
    // neither of which buildozer edits. A dry run keeps what the real run
    // keeps, and both exit 1.
    List<String> kept(ProcessResult result) => [
      for (final line in '${result.stderr}'.split('\n'))
        if (line.contains(': kept ')) line,
    ];
    const unreachable = ['//fix/unused:shared', '//fix/unused:generated'];
    final keptDry = run('unused_deps', [
      '--dry-run',
      ...unreachable,
    ], fails: true);
    final keptReal = run('unused_deps', unreachable, fails: true);
    for (final result in [keptDry, keptReal]) {
      if (result.exitCode != 1) {
        failures.add(
          'unused_deps of unreachable deps exited ${result.exitCode}',
        );
      }
    }
    final keptLines = kept(keptReal);
    if (keptLines.length != 2 ||
        !keptLines.any(
          (l) =>
              l.contains('fix/unused/BUILD.bazel:69:') &&
              l.contains('in a list variable or a comprehension') &&
              l.contains('package(features = ["-dart_unused_deps"])'),
        ) ||
        !keptLines.any(
          (l) => l.contains(
            'a loop or a comprehension may make the target, or a variable name it',
          ),
        )) {
      failures.add('unused_deps of unreachable deps:\n${keptReal.stderr}');
    }
    if ('${kept(keptDry)}' != '$keptLines') {
      failures.add(
        'unused_deps --dry-run kept:\n${kept(keptDry).join('\n')}\n'
        'but the run kept:\n${keptLines.join('\n')}',
      );
    }
    expectFiles('after unused_deps of unreachable deps', originals);

    // A file buildifier would change keeps everything but what is removed.
    const unusedTargets = [
      '//fix/unused:lib',
      '//fix/unused:call.program',
      '//fix/unused:conformance_test',
    ];
    const build = 'fix/unused/BUILD.bazel';
    final untidy = originals[build]!.replaceFirst(_tidy, _untidy);
    if (untidy == originals[build]) failures.add('$build lost its tidy alias');
    file(build).writeAsStringSync(untidy);
    final untidyDry = run('unused_deps', ['--dry-run', ...unusedTargets]);
    if ('${untidyDry.stdout}'.contains('hub_a",   actual') ||
        '${untidyDry.stdout}'.contains('+alias(')) {
      failures.add('unused_deps --dry-run reformatted:\n${untidyDry.stdout}');
    }
    expectFiles('after unused_deps --dry-run of an untidy file', {
      build: untidy,
    });
    run('unused_deps', unusedTargets);
    final left = file(build).readAsLinesSync();
    final gone = untidy.split('\n');
    for (final line in left) {
      if (!gone.remove(line)) failures.add('unused_deps wrote: $line');
    }
    final removedLines = [for (final l in gone) l.trim()]..sort();
    if ('$removedLines' !=
        '${['', '":hub_a",', '":hub_b",', '":leaf",', '":leaf",', '"@rules_dart//dart/runfiles",']}') {
      failures.add('unused_deps of an untidy file removed: $removedLines');
    }
    file(build).writeAsStringSync(originals[build]!);

    // A label buildifier spells otherwise is found, and a file the fixer cannot
    // edit is named and left, without costing the other its fix.
    const twoFiles = ['//fix/unused_spelled:lib', '//fix/unused_joined:lib'];
    final spelled = originals[_spelled]!.replaceFirst(
      _spelledTidy,
      _spelledOtherwise,
    );
    final joined = originals[_joined]!.replaceFirst(_joinedTidy, _joinedApart);
    file(_spelled).writeAsStringSync(spelled);
    file(_joined).writeAsStringSync(joined);
    final twoDry = run('unused_deps', ['--dry-run', ...twoFiles], fails: true);
    if (!'${twoDry.stdout}'.contains('-    deps = [$_spelledOtherwise],') ||
        '${twoDry.stdout}'.contains(_joined) ||
        !'${twoDry.stderr}'.contains('$_joined is not as buildifier')) {
      failures.add(
        'unused_deps --dry-run of two files:\n${twoDry.stdout}${twoDry.stderr}',
      );
    }
    expectFiles('after unused_deps --dry-run of two files', {
      _spelled: spelled,
      _joined: joined,
    });
    final twoReal = run('unused_deps', twoFiles, fails: true);
    if (twoReal.exitCode != 1 ||
        !'${twoReal.stderr}'.contains('$_joined is not as buildifier')) {
      failures.add('unused_deps of two files:\n${twoReal.stderr}');
    }
    expectFiles('after unused_deps of two files', {
      _spelled: spelled.replaceFirst('    deps = [$_spelledOtherwise],\n', ''),
      _joined: joined,
    });
    file(_spelled).writeAsStringSync(originals[_spelled]!);
    file(_joined).writeAsStringSync(originals[_joined]!);

    run('unused_deps', unusedTargets);
    run('fix', ['//fix/dirty:lib', '//fix/dirty_bin:bin']);
    run('format', ['//fix/short_style:lib']);
    run('format', ['--config=deep', '//fix/deep:lib']);
    expectFiles('after fix and format', {
      for (final MapEntry(key: path, value: golden) in _expected.entries)
        path: file(golden).readAsStringSync(),
    });

    // What a fix wrote is what its target's analysis passes, so there is
    // nothing left to do.
    final again = run('fix', ['//fix/dirty:lib', '//fix/dirty_bin:bin']);
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
