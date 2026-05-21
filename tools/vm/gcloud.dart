/// Shared `gcloud` helpers for managing throwaway test VMs.
///
/// Project and zone come from `gcloud config` defaults (run `gcloud config set
/// project ...` and `gcloud config set compute/zone ...` once). VMs created by
/// the sibling scripts are SPOT (preemptible) and self-delete on termination,
/// so a forgotten VM costs little — but delete it explicitly when done:
///
///     gcloud compute instances delete <vm-name> --quiet
library;

import 'dart:io';

/// Runs a `gcloud` command and returns trimmed stdout. Throws on failure.
Future<String> gcloud(List<String> args, {bool quiet = false}) async {
  if (!quiet) {
    stderr.writeln('+ gcloud ${args.join(' ')}');
  }
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
Future<String> getProject() => gcloud(
  ['config', 'get-value', 'project'],
  quiet: true,
);

/// The active gcloud compute zone. Throws if unset.
Future<String> getZone() async {
  final zone = await gcloud(
    ['config', 'get-value', 'compute/zone'],
    quiet: true,
  );
  if (zone.isEmpty || zone == '(unset)') {
    throw Exception(
      'No default compute zone set. Run: gcloud config set compute/zone <zone>',
    );
  }
  return zone;
}

/// Blocks until [vmName] accepts SSH (or [timeout] elapses).
Future<void> waitForSsh(
  String vmName, {
  Duration timeout = const Duration(minutes: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  stderr.writeln('Waiting for $vmName to accept SSH ...');
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run('gcloud', [
      'compute',
      'ssh',
      vmName,
      '--command',
      'echo ready',
      '--ssh-flag=-o',
      '--ssh-flag=ConnectTimeout=5',
      '--ssh-flag=-o',
      '--ssh-flag=StrictHostKeyChecking=no',
    ]);
    if (result.exitCode == 0) {
      stderr.writeln('$vmName is ready.');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  throw Exception('Timeout waiting for $vmName SSH');
}

/// SCPs a local file/directory to the VM. `--scp-flag=-O` forces the legacy
/// SCP protocol, required for Windows OpenSSH compatibility.
Future<void> scpToVm(
  String vmName,
  String localPath,
  String remotePath, {
  bool compress = false,
}) async {
  await gcloud([
    'compute',
    'scp',
    '--recurse',
    '--scp-flag=-O',
    if (compress) '--compress',
    localPath,
    '$vmName:$remotePath',
  ]);
}

/// SCPs a remote file/directory from the VM to a local path.
Future<void> scpFromVm(
  String vmName,
  String remotePath,
  String localPath, {
  bool compress = false,
}) async {
  await gcloud([
    'compute',
    'scp',
    '--recurse',
    '--scp-flag=-O',
    if (compress) '--compress',
    '$vmName:$remotePath',
    localPath,
  ]);
}

/// Runs [command] on the VM via SSH, returning trimmed stdout. Throws on a
/// non-zero exit. Use [sshExec] when you need the exit code or stderr.
Future<String> sshRun(String vmName, String command) =>
    gcloud(['compute', 'ssh', vmName, '--command', command]);

/// Runs [command] on the VM via SSH and returns the full [ProcessResult]
/// (stdout, stderr, exitCode) without throwing — for commands whose non-zero
/// exit is meaningful (e.g. a failing test run).
Future<ProcessResult> sshExec(String vmName, String command) {
  stderr.writeln('+ ssh $vmName: $command');
  return Process.run('gcloud', [
    'compute',
    'ssh',
    vmName,
    '--command',
    command,
  ]);
}

/// Deletes [vmName].
Future<void> deleteVm(String vmName) =>
    gcloud(['compute', 'instances', 'delete', vmName, '--quiet']);
