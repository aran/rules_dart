/// Runs the rules_dart e2e suites on a remote VM over SSH.
///
/// Usage:
///
///     bazel run //tools/vm:run_e2e -- <vm-name> [--windows] \
///         [--folders=e2e/ext_exemplar,e2e/dart_test] [--keep-going]
///
/// Transfers the committed working tree (`git archive HEAD`) to the VM,
/// extracts it, then does what `.github/workflows/ci.yaml` at HEAD does: the
/// `test` job's command in each of its folders, and on Linux, when no
/// `--folders` are given, every step of the `expected-failure` job in its
/// working directory. Prints a per-folder PASS/FAIL summary and exits non-zero
/// if any failed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../tool/ci_workflow.dart';
import 'gcloud.dart';

/// The job whose steps each check a failure rules_dart must report.
const _expectedFailureJob = 'expected-failure';

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
  final repoRoot = _repoRoot();
  _warnIfDirty(repoRoot);
  final workflow = CiWorkflow.parse(
    _run('git', ['-C', repoRoot, 'show', 'HEAD:.github/workflows/ci.yaml']),
  );
  final folders = foldersArg.isEmpty
      ? workflow.testFolders
      : foldersArg.split(',').map((s) => s.trim()).toList();

  // 1. Package the committed tree.
  final tgz = '${Directory.systemTemp.path}/rules_dart_src.tgz';
  stdout.writeln('Packaging committed HEAD -> $tgz');
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
  stdout.writeln('Transferring source tree to $vmName ...');
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
    // A repository, as CI's checkout is: steps restore what they edit with
    // `git checkout`.
    await sshRun(
      vmName,
      "bash -lc 'rm -rf ~/rd && mkdir -p ~/rd && "
      "tar xzf ~/rules_dart_src.tgz -C ~/rd && cd ~/rd/rules_dart && "
      "git init -q && git add -A && "
      "git -c user.name=e2e -c user.email=e2e@localhost commit -qm HEAD'",
    );
  }

  // 3. Run each folder.
  final results = <_FolderResult>[];
  for (final folder in folders) {
    stdout.writeln('\n=== $folder ===');
    final result = await _runFolder(
      vmName,
      folder,
      workflow.testCommand,
      noTests: workflow.noTestFolders.contains(folder),
      isWindows: isWindows,
    );
    results.add(result);
    stdout.writeln(
      '${result.pass ? "PASS" : "FAIL"} $folder (exit ${result.exitCode})',
    );
    if (!result.pass && !keepGoing) {
      stdout.writeln('Stopping (use --keep-going to run the rest).');
      break;
    }
  }

  // 4. The expected-failure job's steps (Linux only, as in CI).
  final expectedFailures = <_FolderResult>[];
  if (!isWindows && foldersArg.isEmpty) {
    for (final step in workflow.job(_expectedFailureJob).steps) {
      final script = step.run;
      if (script == null) continue;
      stdout.writeln('\n=== ${step.name} ===');
      final r = await _runScript(vmName, step.workingDirectory, script);
      final result = _FolderResult(
        '${step.workingDirectory}: ${step.name}',
        r.exitCode,
        r.exitCode == 0,
        r.tail,
      );
      expectedFailures.add(result);
      stdout.writeln(
        '${result.pass ? "PASS" : "FAIL"} ${result.folder} '
        '(exit ${result.exitCode})',
      );
    }
  }

  // 5. Summary.
  final all = [...results, ...expectedFailures];
  stdout.writeln(
    '\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========',
  );
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

/// Runs CI's [command] in [folder]. On Linux the command is CI's own, which
/// decides what passes; Windows runs `bazel test //...` from `cmd`, passing
/// on 0, and on 4 (no test targets) where [noTests] says CI's command does.
Future<_FolderResult> _runFolder(
  String vmName,
  String folder,
  String command, {
  required bool noTests,
  required bool isWindows,
}) async {
  if (!isWindows) {
    final r = await _runScript(vmName, folder, command);
    return _FolderResult(folder, r.exitCode, r.exitCode == 0, r.tail);
  }
  final winFolder = folder == '.'
      ? 'C:\\rd\\rules_dart'
      : 'C:\\rd\\rules_dart\\${folder.replaceAll('/', '\\')}';
  // /v:on enables delayed expansion so !errorlevel! is bazel's real exit,
  // not the parse-time value. --output_user_root keeps paths under MAX_PATH.
  final ProcessResult result;
  try {
    result = await sshExec(
      vmName,
      'cmd /v:on /c "cd /d $winFolder && '
      'bazel --output_user_root=C:/b test --test_output=errors //... & '
      'echo RD_EXIT=!errorlevel!"',
    ).timeout(_folderTimeout);
  } on TimeoutException {
    return _FolderResult(folder, -2, false, 'TIMEOUT after $_folderTimeout');
  }
  final exitCode = _parseRdExit(result.stdout.toString());
  return _FolderResult(
    folder,
    exitCode,
    exitCode == 0 || (exitCode == 4 && noTests),
    _tail('${result.stdout}\n${result.stderr}'),
  );
}

/// Runs [script] with bash on the Linux VM in [dir] (relative to the
/// checkout), as a GitHub Actions `run` step does (`bash -e -o pipefail`).
Future<({int exitCode, String tail})> _runScript(
  String vmName,
  String dir,
  String script,
) async {
  final path = dir == '.' ? '' : '/$dir';
  // Base64 carries the script through the SSH command line unquoted.
  final encoded = base64.encode(utf8.encode(script));
  final command =
      "bash -lc 'cd \$HOME/rd/rules_dart$path && "
      'echo $encoded | base64 -d > /tmp/rd_step.sh && '
      "bash -e -o pipefail /tmp/rd_step.sh; echo RD_EXIT=\$?'";
  final ProcessResult result;
  try {
    result = await sshExec(vmName, command).timeout(_folderTimeout);
  } on TimeoutException {
    return (exitCode: -2, tail: 'TIMEOUT after $_folderTimeout');
  }
  return (
    exitCode: _parseRdExit(result.stdout.toString()),
    tail: _tail('${result.stdout}\n${result.stderr}'),
  );
}

/// Waits until the VM's toolchain (bazel + C compiler) is installed.
Future<void> _waitForToolchain(String vmName, {required bool isWindows}) async {
  stdout.writeln('Verifying toolchain on $vmName ...');
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
      if (r.exitCode == 0 && r.stdout.toString().contains('STARTUP_COMPLETE')) {
        return;
      }
    } else {
      r = await sshExec(vmName, 'bash -lc "command -v bazel && command -v cc"');
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

String _run(String exe, List<String> args) {
  final r = Process.runSync(exe, args);
  if (r.exitCode != 0) {
    throw Exception('$exe ${args.join(' ')} failed:\n${r.stderr}');
  }
  return r.stdout as String;
}
