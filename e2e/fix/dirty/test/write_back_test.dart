import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Drives the `bazel run` half of `dart_fix` — the part that writes into a
/// source tree — without nesting a Bazel invocation inside a test.
///
/// The executable a `dart_fix` target produces is a self-contained binary that
/// learns where to write from `BUILD_WORKSPACE_DIRECTORY`, and takes its inputs
/// from `--manifest` / `--fixes` when `bazel run`'s environment is not there to
/// supply them. Pointing that at a throwaway copy of the fixture under
/// `TEST_TMPDIR` exercises the real write path hermetically; the build-time
/// diff_tests next to this one already cover *what* gets written, so this
/// covers only that it lands in the right file and that `--dry-run` does not.

/// The one file `//dirty:fix` may write, relative to the workspace root.
const _fixedRelative = 'dirty/lib/model.dart';

void main() {
  final r = Runfiles.create();
  final failures = <String>[];

  final exe = r.rlocation(
    Platform.isWindows ? '_main/dirty/fix.exe' : '_main/dirty/fix',
  );
  final manifest = r.rlocation('_main/dirty/fix.fix_manifest.json');

  // The fixes tree is a directory, and a directory has no runfiles entry of its
  // own in manifest mode. Locating the one file inside it and walking back up
  // gets the root in either mode.
  //
  // The number of hops is derived from the path rather than written out, so
  // moving the fixture a directory deeper cannot silently point the applier at
  // the wrong root.
  var fixesDir = File(
    r.rlocation('_main/dirty/fix.fixes/$_fixedRelative'),
  ).parent;
  for (var i = 1; i < _fixedRelative.split('/').length; i++) {
    fixesDir = fixesDir.parent;
  }
  final fixes = fixesDir.path;

  final before = File(r.rlocation('_main/$_fixedRelative')).readAsStringSync();
  final after = File(
    r.rlocation('_main/clean/lib/model.dart'),
  ).readAsStringSync();

  final dry = _run(exe, manifest, fixes, before, dryRun: true);
  if (dry.tree != before) {
    failures.add('--dry-run modified $_fixedRelative');
  }
  for (final expected in [
    '--- a/$_fixedRelative',
    '+  @override',
    '+    final label = modelLabel();',
  ]) {
    if (!dry.stdout.contains(expected)) {
      failures.add('--dry-run diff is missing "$expected":\n${dry.stdout}');
    }
  }

  final wet = _run(exe, manifest, fixes, before, dryRun: false);
  if (wet.tree != after) {
    failures.add(
      'write-back produced unexpected content for $_fixedRelative:\n${wet.tree}',
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('FAIL: ${failures.length} problem(s):');
    for (final f in failures) {
      stderr.writeln('  - $f');
    }
    exit(1);
  }
  print('PASS: --dry-run left the tree alone; the real run wrote the fix.');
}

/// The state of a scratch workspace after one applier run.
class _Result {
  _Result(this.stdout, this.tree);

  final String stdout;

  /// Contents of [_fixedRelative] in the scratch workspace afterwards.
  final String tree;
}

/// Runs the applier against a fresh scratch workspace seeded with [seed].
_Result _run(
  String exe,
  String manifest,
  String fixes,
  String seed, {
  required bool dryRun,
}) {
  final workspace = Directory(
    '${Platform.environment['TEST_TMPDIR']}/${dryRun ? 'dry' : 'wet'}',
  );
  final target = File('${workspace.path}/$_fixedRelative');
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(seed);

  final result = Process.runSync(
    exe,
    ['--manifest', manifest, '--fixes', fixes, if (dryRun) '--dry-run'],
    environment: {'BUILD_WORKSPACE_DIRECTORY': workspace.path},
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw StateError('fix applier exited ${result.exitCode}');
  }
  return _Result(result.stdout as String, target.readAsStringSync());
}
