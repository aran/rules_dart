/// Runs the rules_dart e2e suites on a remote VM over SSH.
///
/// Usage:
///   dart run tools/vm/run_e2e.dart <vm-name> [--windows] \
///       [--folders=e2e/ext_exemplar,e2e/dart_test] [--keep-going]
///
/// Transfers the committed working tree (`git archive HEAD`) to the VM,
/// extracts it, then runs `bazel test //...` in each CI folder, mirroring
/// `.github/workflows/ci.yaml` (exit code 4 — "no test targets" — counts as a
/// pass, as do build-only folders). Prints a per-folder PASS/FAIL summary and
/// exits non-zero if any folder failed.
///
/// The Linux-only `pub_lock_conflict` workspace is an *expected failure*: its
/// build must fail with a specific error. It is checked separately on Linux.
library;

import 'dart:async';
import 'dart:io';

import 'gcloud.dart';

/// The `folders` matrix from `.github/workflows/ci.yaml` (the `test` job).
const _ciFolders = [
  '.',
  'e2e/smoke',
  'e2e/hello_world',
  'e2e/library_deps',
  'e2e/analysis',
  'e2e/dart_test',
  'e2e/dart_test_pkg',
  'e2e/codegen',
  'e2e/pub_deps',
  'e2e/pub_lock',
  'e2e/web_app',
  'e2e/gazelle',
  'e2e/cross_compile',
  'e2e/pub_lock_cross_module',
  'e2e/pub_lock_dedup',
  'e2e/pub_lock_upgrade',
  'e2e/ext_exemplar',
  'e2e/dual_build',
];

/// Per-folder timeout. The first folder pays for the hermetic Dart SDK
/// download + dependency fetch; later folders re-fetch (separate output bases).
const _folderTimeout = Duration(minutes: 30);

class _FolderResult {
  _FolderResult(this.folder, this.exitCode, this.pass, this.tail);
  final String folder;
  final int exitCode;
  final bool pass;
  final String tail;
}

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
      '[--folders=a,b,c] [--keep-going]',
    );
    exit(2);
  }
  final vmName = positional.first;
  final isWindows = args.contains('--windows');
  final keepGoing = args.contains('--keep-going');
  final foldersArg = args
      .firstWhere((a) => a.startsWith('--folders='), orElse: () => '')
      .replaceFirst('--folders=', '');
  final folders = foldersArg.isEmpty
      ? _ciFolders
      : foldersArg.split(',').map((s) => s.trim()).toList();

  final repoRoot = _repoRoot();
  _warnIfDirty(repoRoot);

  // 1. Package the committed tree.
  final tgz = '${Directory.systemTemp.path}/rules_dart_src.tgz';
  print('Packaging committed HEAD -> $tgz');
  _run('git', [
    '-C',
    repoRoot,
    'archive',
    '--format=tar.gz',
    '--prefix=rules_dart/',
    '-o',
    tgz,
    'HEAD',
  ]);

  // 2. Wait for the toolchain, then transfer + extract.
  await _waitForToolchain(vmName, isWindows: isWindows);
  print('Transferring source tree to $vmName ...');
  if (isWindows) {
    await scpToVm(vmName, tgz, 'C:/rd_src.tgz', compress: true);
    // Separate, simple commands. A single compound `cmd /c "... & ... & ..."`
    // mangles through gcloud ssh -> Windows cmd and can silently no-op (return
    // 0 while doing nothing), which then fails every folder's `cd`.
    await sshExec(vmName, 'rmdir /s /q C:\\rd'); // tolerate "not found"
    await sshRun(vmName, 'mkdir C:\\rd');
    await sshRun(vmName, 'tar -xf C:\\rd_src.tgz -C C:\\rd');
  } else {
    await scpToVm(vmName, tgz, '~/rules_dart_src.tgz', compress: true);
    await sshRun(
      vmName,
      "bash -lc 'rm -rf ~/rd && mkdir -p ~/rd && "
      "tar xzf ~/rules_dart_src.tgz -C ~/rd'",
    );
  }

  // 3. Run each folder.
  final results = <_FolderResult>[];
  for (final folder in folders) {
    stdout.writeln('\n=== $folder ===');
    final result = await _runFolder(vmName, folder, isWindows: isWindows);
    results.add(result);
    stdout.writeln(
      '${result.pass ? "PASS" : "FAIL"} $folder (exit ${result.exitCode})',
    );
    if (!result.pass && !keepGoing) {
      stdout.writeln('Stopping (use --keep-going to run the rest).');
      break;
    }
  }

  // 4. Expected-failure check (Linux only, mirrors ci.yaml).
  _FolderResult? conflict;
  if (!isWindows && foldersArg.isEmpty) {
    stdout.writeln('\n=== e2e/pub_lock_conflict (expected failure) ===');
    conflict = await _runExpectedFailure(vmName);
    stdout.writeln(
      '${conflict.pass ? "PASS" : "FAIL"} e2e/pub_lock_conflict '
      '(exit ${conflict.exitCode})',
    );
  }

  // 5. Summary.
  final all = [...results, if (conflict != null) conflict];
  stdout.writeln('\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========');
  for (final r in all) {
    stdout.writeln('  ${r.pass ? "PASS" : "FAIL"}  ${r.folder}');
  }
  final failed = all.where((r) => !r.pass).toList();
  if (failed.isEmpty) {
    stdout.writeln('\nAll ${all.length} folders passed.');
    exit(0);
  }
  stdout.writeln('\n${failed.length} folder(s) FAILED:');
  for (final r in failed) {
    stdout.writeln('\n----- ${r.folder} (exit ${r.exitCode}) -----');
    stdout.writeln(r.tail);
  }
  exit(1);
}

/// Runs `bazel test //...` in [folder] and maps the exit code: 0 (success) and
/// 4 (no test targets) pass; anything else fails.
Future<_FolderResult> _runFolder(
  String vmName,
  String folder, {
  required bool isWindows,
}) async {
  final String command;
  if (isWindows) {
    final winFolder = folder == '.'
        ? 'C:\\rd\\rules_dart'
        : 'C:\\rd\\rules_dart\\${folder.replaceAll('/', '\\')}';
    // /v:on enables delayed expansion so !errorlevel! is bazel's real exit,
    // not the parse-time value. --output_user_root keeps paths under MAX_PATH.
    command =
        'cmd /v:on /c "cd /d $winFolder && '
        'bazel --output_user_root=C:/b test --test_output=errors //... & '
        'echo RD_EXIT=!errorlevel!"';
  } else {
    final dir = folder == '.'
        ? '\$HOME/rd/rules_dart'
        : '\$HOME/rd/rules_dart/$folder';
    command =
        "bash -lc 'cd $dir && "
        "bazel test --test_output=errors //...; echo RD_EXIT=\$?'";
  }

  final ProcessResult result;
  try {
    result = await sshExec(vmName, command).timeout(_folderTimeout);
  } on TimeoutException {
    return _FolderResult(folder, -2, false, 'TIMEOUT after $_folderTimeout');
  }

  final combined = '${result.stdout}\n${result.stderr}';
  final exitCode = _parseRdExit(result.stdout.toString());
  final pass = exitCode == 0 || exitCode == 4;
  return _FolderResult(folder, exitCode, pass, _tail(combined));
}

/// Checks `e2e/pub_lock_conflict`: the build must fail with the cross-lockfile
/// conflict error (mirrors the `expected-failure` job in ci.yaml).
Future<_FolderResult> _runExpectedFailure(String vmName) async {
  const dir = '\$HOME/rd/rules_dart/e2e/pub_lock_conflict';
  final command =
      "bash -lc 'cd $dir && "
      "bazel build //:app > /tmp/conflict.out 2>&1; "
      "if grep -q \"conflicting versions across lock files\" /tmp/conflict.out; "
      "then echo RD_EXIT=0; else echo RD_EXIT=1; fi'";
  final ProcessResult result;
  try {
    result = await sshExec(vmName, command).timeout(_folderTimeout);
  } on TimeoutException {
    return _FolderResult(
      'e2e/pub_lock_conflict',
      -2,
      false,
      'TIMEOUT after $_folderTimeout',
    );
  }
  final exitCode = _parseRdExit(result.stdout.toString());
  return _FolderResult(
    'e2e/pub_lock_conflict',
    exitCode,
    exitCode == 0,
    _tail('${result.stdout}\n${result.stderr}'),
  );
}

/// Waits until the VM's toolchain (bazel + C compiler) is installed.
Future<void> _waitForToolchain(String vmName, {required bool isWindows}) async {
  print('Verifying toolchain on $vmName ...');
  // Generous: a fresh Windows VM may need ~15 min before SSH, then ~15 min
  // to finish installing MSVC + bazelisk via the startup script.
  final deadline = DateTime.now().add(const Duration(minutes: 40));
  while (DateTime.now().isBefore(deadline)) {
    final ProcessResult r;
    if (isWindows) {
      r = await sshExec(
        vmName,
        'cmd /c "type C:\\startup_complete.txt && where bazel"',
      );
      if (r.exitCode == 0 &&
          r.stdout.toString().contains('STARTUP_COMPLETE')) {
        return;
      }
    } else {
      r = await sshExec(
        vmName,
        'bash -lc "command -v bazel && command -v cc"',
      );
      if (r.exitCode == 0) return;
    }
    stdout.writeln('  toolchain not ready yet; waiting ...');
    await Future<void>.delayed(const Duration(seconds: 20));
  }
  throw Exception('Timed out waiting for toolchain on $vmName');
}

int _parseRdExit(String stdout) {
  final m = RegExp(r'RD_EXIT=(-?\d+)').firstMatch(stdout);
  return m == null ? -1 : int.parse(m.group(1)!);
}

String _tail(String s, {int lines = 60}) {
  final all = s.split('\n');
  return all.length <= lines ? s : all.sublist(all.length - lines).join('\n');
}

String _repoRoot() {
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) {
    throw Exception('Not in a git repo: ${r.stderr}');
  }
  return r.stdout.toString().trim();
}

void _warnIfDirty(String repoRoot) {
  final r = Process.runSync('git', [
    '-C',
    repoRoot,
    'status',
    '--porcelain',
    '--untracked-files=no',
  ]);
  if (r.stdout.toString().trim().isNotEmpty) {
    stderr.writeln(
      'WARNING: tracked working-tree changes are NOT included — '
      'run_e2e tests committed HEAD only. Commit first to test them.',
    );
  }
}

void _run(String exe, List<String> args) {
  final r = Process.runSync(exe, args);
  if (r.exitCode != 0) {
    throw Exception('$exe ${args.join(' ')} failed:\n${r.stderr}');
  }
}
