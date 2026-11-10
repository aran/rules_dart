// Checks, or rewrites, the MODULE.bazel.lock of every Bazel workspace in the
// repository it runs in. `check.dart` and `refresh.dart` are the two entry
// points; each calls [runLocks].
//
//   bazel run @overhead//locks:check                      check every workspace
//   bazel run @overhead//locks:check -- e2e/smoke         check some
//   bazel run --lockfile_mode=off @overhead//locks:refresh
//                                                         rewrite every lock
//   bazel run --lockfile_mode=off @overhead//locks:refresh -- e2e/smoke
//                                                         rewrite some
//
// A refresh builds the tool with `--lockfile_mode=off`, which neither reads
// nor writes the root lock: a stale root lock cannot stop the tool, and local
// `--override_module` flags in `.bazelrc.user` cannot leak into that lock. The
// tool then rewrites the root lock itself, without `.bazelrc.user`. A check
// needs no flag.
//
// A check runs `bazel mod deps` and `bazel build --nobuild //...` with
// `--lockfile_mode=error`; a refresh runs `bazel mod tidy` and then the same
// two with `--lockfile_mode=update`. Bazel reads each workspace's committed
// `.bazelrc` but not its `.bazelrc.user`, whose overrides would otherwise end
// up in the lock (lock_workspaces.dart, `withoutUserRc`), nor the system's or
// the home's.
//
// A workspace that fails on purpose holds a `lock_expected_failure.txt`
// listing what its failure prints; a step that fails printing all of it
// passes, and so does any step after it. The rest of such a workspace's lock
// is still checked and written; a refresh writes it from nothing, since a
// failing extension would otherwise keep its stale entry.
import 'dart:io';

import 'lock_workspaces.dart';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

/// Checks, or with [refresh] rewrites, the locks of the workspaces [named], or
/// of every workspace when none is.
Future<void> runLocks({
  required bool refresh,
  required List<String> named,
}) async {
  final listing = await Process.run('git', [
    'ls-files',
    '-z',
  ], workingDirectory: _repo);
  if (listing.exitCode != 0) {
    stderr.writeln('locks: git ls-files failed: ${listing.stderr}');
    exit(2);
  }
  final rootModule = File('$_repo/MODULE.bazel');
  final workspaces = findWorkspaces(
    (listing.stdout as String).split('\x00').where((p) => p.isNotEmpty),
    rootOverrides: rootModule.existsSync()
        ? localPathOverrides(rootModule.readAsStringSync())
        : const {},
  );

  final unknown = named.where((w) => !workspaces.contains(w)).toList();
  if (unknown.isNotEmpty || named.any((w) => w.startsWith('-'))) {
    stderr.writeln('locks: not a workspace: ${unknown.join(', ')}');
    stderr.writeln('usage: ${refresh ? 'refresh' : 'check'} [<workspace>...]');
    stderr.writeln('workspaces:\n  ${workspaces.join('\n  ')}');
    exit(2);
  }
  final targets = named.isEmpty ? workspaces : named;
  final steps = refresh ? refreshSteps : checkSteps;

  final scratch = await Directory.systemTemp.createTemp('locks');
  final failed = <String>[];
  try {
    for (final workspace in targets) {
      if (!await _run(workspace, steps, scratch)) failed.add(workspace);
    }
  } finally {
    await scratch.delete(recursive: true);
  }

  final verb = refresh ? 'refreshed' : 'checked';
  if (failed.isEmpty) {
    stdout.writeln('locks: ${targets.length} workspace(s) $verb');
    return;
  }
  stderr.writeln('\nlocks: ${failed.length} of ${targets.length} failed:');
  for (final workspace in failed) {
    stderr.writeln('  $workspace');
  }
  if (!refresh) {
    stderr.writeln(
      '\nWhere Bazel says a lock is out of date, rewrite it with '
      '`bazel run --lockfile_mode=off @overhead//locks:refresh -- '
      '<workspace>`.',
    );
  }
  exit(1);
}

/// Runs [steps] in [workspace]; prints each outcome and returns whether all
/// passed.
Future<bool> _run(
  String workspace,
  List<LockStep> steps,
  Directory scratch,
) async {
  final dir = workspace == '.' ? _repo : '$_repo/$workspace';
  final marker = File('$dir/$expectedFailureFile');
  final expected = marker.existsSync()
      ? expectedFailureTexts(marker.readAsStringSync())
      : null;
  if (expected != null && expected.isEmpty) {
    stderr.writeln(
      'FAILED $workspace: $expectedFailureFile lists no text its failure '
      'prints',
    );
    return false;
  }
  final rcFile = _writeRc(dir, workspace, scratch);

  // An extension that fails keeps whatever entry the lock had for it, stale
  // or not, so a workspace that fails on purpose is rewritten from nothing.
  final lock = File('$dir/MODULE.bazel.lock');
  if (expected != null && steps == refreshSteps && lock.existsSync()) {
    lock.deleteSync();
  }

  try {
    return await _runSteps(workspace, dir, steps, rcFile, expected) &&
        await _holdsNoHostPath(workspace, lock, rcFile);
  } finally {
    // Each workspace starts its own Bazel server; walking every workspace of
    // a repository would otherwise leave dozens of idle servers holding memory.
    await Process.run('bazel', [
      ...rcArgs(rcFile),
      'shutdown',
    ], workingDirectory: dir);
  }
}

Future<bool> _runSteps(
  String workspace,
  String dir,
  List<LockStep> steps,
  String? rcFile,
  List<String>? expected,
) async {
  var afterExpectedFailure = false;
  for (final step in steps) {
    final watch = Stopwatch()..start();
    final result = await Process.run(
      'bazel',
      bazelArgs(step, rcFile: rcFile),
      workingDirectory: dir,
    );
    final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    final output = '${result.stdout}\n${result.stderr}';
    if (stepPasses(
      result.exitCode,
      output,
      expected,
      afterExpectedFailure: afterExpectedFailure,
    )) {
      final how = result.exitCode == 0 ? '' : ', failed as expected';
      stdout.writeln('ok     $workspace: ${step.label} (${seconds}s$how)');
      afterExpectedFailure |= failedAsExpected(
        result.exitCode,
        output,
        expected,
      );
      continue;
    }
    stderr.writeln(
      'FAILED $workspace: ${step.label} exited ${result.exitCode}'
      '${expected == null ? '' : ' without printing what $expectedFailureFile expects'}',
    );
    final pin = unfetchablePin(output);
    stderr.writeln(pin == null ? _tail(output) : '    $pin');
    return false;
  }
  return true;
}

/// Whether [lock] holds no path of this machine: the checkout, Bazel's output
/// root or the home directory. Prints each line that does.
Future<bool> _holdsNoHostPath(
  String workspace,
  File lock,
  String? rcFile,
) async {
  if (!lock.existsSync()) return true;
  final info = await Process.run('bazel', [
    ...rcArgs(rcFile),
    'info',
    '--lockfile_mode=off',
    'output_base',
  ], workingDirectory: lock.parent.path);
  if (info.exitCode != 0) {
    stderr.writeln(
      'FAILED $workspace: bazel info output_base exited ${info.exitCode}',
    );
    stderr.writeln(_tail('${info.stdout}\n${info.stderr}'));
    return false;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final checkout = Directory(_repo);
  final roots = [
    ('the checkout', checkout.path),
    ('the checkout', checkout.resolveSymbolicLinksSync()),
    ("Bazel's output root", File((info.stdout as String).trim()).parent.path),
    if (home != null) ('the home directory', home),
  ];
  final found = hostPaths(lock.readAsStringSync(), roots);
  if (found.isEmpty) return true;
  final name = workspace == '.'
      ? 'MODULE.bazel.lock'
      : '$workspace/MODULE.bazel.lock';
  stderr.writeln(
    'FAILED $workspace: the lock holds paths of this machine, so it holds '
    'only here; a repository attribute must name a file by a label, not a '
    'path:',
  );
  for (final at in found) {
    stderr.writeln('    $name:${at.line}: ${at.path} (under ${at.root})');
  }
  return false;
}

/// A copy of the workspace's `.bazelrc` without its `.bazelrc.user`, or null
/// when it has none.
String? _writeRc(String dir, String workspace, Directory scratch) {
  final committed = File('$dir/.bazelrc');
  if (!committed.existsSync()) return null;
  final user = File('$dir/.bazelrc.user');
  final copy = File(
    '${scratch.path}/${workspace.replaceAll('/', '_')}.bazelrc',
  );
  copy.writeAsStringSync(
    withoutUserRc(
      committed.readAsStringSync(),
      userRc: user.existsSync() ? user.readAsStringSync() : '',
    ),
  );
  return copy.path;
}

/// The last lines of Bazel's output, where it says what is wrong.
String _tail(String output, {int lines = 25}) {
  final all = output.trimRight().split('\n');
  final kept = all.length <= lines ? all : all.sublist(all.length - lines);
  return kept.map((l) => '    $l').join('\n');
}
