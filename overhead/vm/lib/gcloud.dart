/// `gcloud` helpers for the throwaway test VMs: create, reach, copy to, delete.
///
/// The project comes from `gcloud config`; the zone from
/// `CLOUDSDK_COMPUTE_ZONE` when it is set, else from `gcloud config`
/// (`gcloud config set compute/zone <zone>` once). The VMs are SPOT: the zone
/// can reclaim one at any time, and its termination action deletes it, disk
/// and all, so a forgotten VM costs little. Delete one when done:
///
///     gcloud compute instances delete <vm-name> --quiet
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs a `gcloud` command and returns its trimmed stdout. Throws on failure.
Future<String> gcloud(List<String> args, {bool quiet = false}) async {
  if (!quiet) stderr.writeln('+ gcloud ${args.join(' ')}');
  final result = await Process.run('gcloud', args);
  if (result.exitCode != 0) {
    throw Exception(
      'gcloud ${args.join(' ')} failed (exit ${result.exitCode}):\n'
      '${result.stderr}',
    );
  }
  return result.stdout.toString().trim();
}

/// The active gcloud project.
Future<String> project() =>
    gcloud(['config', 'get-value', 'project'], quiet: true);

/// The compute zone: `CLOUDSDK_COMPUTE_ZONE`, else `gcloud config`'s. Throws
/// when neither names one.
Future<String> zone() async {
  final fromEnv = Platform.environment['CLOUDSDK_COMPUTE_ZONE'] ?? '';
  if (fromEnv.isNotEmpty) return fromEnv;
  final configured = await gcloud([
    'config',
    'get-value',
    'compute/zone',
  ], quiet: true);
  if (configured.isEmpty || configured == '(unset)') {
    throw Exception(
      'No compute zone. Set CLOUDSDK_COMPUTE_ZONE, or run: '
      'gcloud config set compute/zone <zone>',
    );
  }
  return configured;
}

/// The VM's status (`RUNNING`, `STOPPING`, `TERMINATED`, ...), or null when
/// there is no such VM, as after a spot VM is preempted and deleted.
Future<String?> instanceStatus(String vmName) async {
  final result = await Process.run('gcloud', [
    'compute',
    'instances',
    'describe',
    vmName,
    '--format=value(status)',
  ]);
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim();
}

/// Blocks until [vmName] runs a command over SSH, or [timeout] elapses.
Future<void> waitForSsh(
  String vmName, {
  Duration timeout = const Duration(minutes: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  stderr.writeln('Waiting for $vmName to accept SSH ...');
  while (DateTime.now().isBefore(deadline)) {
    // Each attempt is bounded: a Windows VM's sshd can accept and
    // authenticate a connection while sysprep is still running and then never
    // run the command, which ssh's ConnectTimeout does not cover.
    final attempt = await ssh(
      vmName,
      'echo ready',
      timeout: const Duration(minutes: 1),
      quiet: true,
      sshFlags: const [
        '-o',
        'ConnectTimeout=5',
        '-o',
        'StrictHostKeyChecking=no',
      ],
    );
    if (attempt.exitCode == 0 && attempt.stdout.toString().contains('ready')) {
      stderr.writeln('$vmName is ready.');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  throw Exception('Timeout waiting for $vmName SSH');
}

/// Copies a local file or directory to the VM. `--scp-flag=-O` forces the
/// legacy SCP protocol, which Windows' OpenSSH needs.
Future<void> scpToVm(
  String vmName,
  String localPath,
  String remotePath, {
  bool compress = false,
}) => gcloud([
  'compute',
  'scp',
  '--recurse',
  '--scp-flag=-O',
  if (compress) '--compress',
  localPath,
  '$vmName:$remotePath',
]);

/// Copies a file or directory from the VM to a local path.
Future<void> scpFromVm(
  String vmName,
  String remotePath,
  String localPath, {
  bool compress = false,
}) => gcloud([
  'compute',
  'scp',
  '--recurse',
  '--scp-flag=-O',
  if (compress) '--compress',
  '$vmName:$remotePath',
  localPath,
]);

/// Runs [command] on the VM over SSH and returns its trimmed stdout. Throws on
/// a non-zero exit; [ssh] returns the exit instead.
Future<String> sshRun(String vmName, String command) =>
    gcloud(['compute', 'ssh', vmName, '--command', command]);

/// Exit code [ssh] reports when [ssh]'s timeout ended the command.
const sshTimedOut = -2;

/// Runs [command] on the VM over SSH and returns its result without throwing,
/// for a command whose non-zero exit means something (a failing test run).
/// With [timeout], the SSH session is killed when it runs out, and the
/// result's exit code is [sshTimedOut].
Future<ProcessResult> ssh(
  String vmName,
  String command, {
  Duration? timeout,
  bool quiet = false,
  List<String> sshFlags = const [],
}) async {
  if (!quiet) stderr.writeln('+ ssh $vmName: $command');
  final process = await Process.start('gcloud', [
    'compute',
    'ssh',
    vmName,
    '--command',
    command,
    for (final flag in sshFlags) '--ssh-flag=$flag',
  ]);
  final out = process.stdout.transform(systemEncoding.decoder).join();
  final err = process.stderr.transform(systemEncoding.decoder).join();
  final exitCode = await (timeout == null
      ? process.exitCode
      : process.exitCode.timeout(
          timeout,
          onTimeout: () {
            process.kill();
            return sshTimedOut;
          },
        ));
  // Killing gcloud can leave its ssh child holding the pipes open, so a
  // killed session's output is whatever arrives soon after.
  Future<String> drained(Future<String> text) => exitCode == sshTimedOut
      ? text.timeout(const Duration(seconds: 5), onTimeout: () => '')
      : text;
  return ProcessResult(
    process.pid,
    exitCode,
    await drained(out),
    await drained(err),
  );
}

/// Deletes [vmName].
Future<void> deleteVm(String vmName) =>
    gcloud(['compute', 'instances', 'delete', vmName, '--quiet']);

/// [text] as one base64 word, which crosses an SSH command line unquoted.
String base64Word(String text) => base64.encode(utf8.encode(text));
