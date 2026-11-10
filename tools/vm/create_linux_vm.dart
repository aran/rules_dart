/// Creates a SPOT Linux VM for running the rules_dart e2e suites on Linux.
///
/// Usage: dart run tools/vm/create_linux_vm.dart [vm-name]
///
/// The VM gets a C/C++ toolchain (for `cc_shared_library`, e.g. the sqlite3
/// code asset), `bazelisk` (which reads `.bazelversion`), and the basics
/// Bazel needs. The Dart SDK is **not** installed — rules_dart's toolchain
/// fetches it hermetically.
///
/// After creation, run the suites with:
///   dart run tools/vm/run_e2e.dart <vm-name>
library;

import 'dart:io';

import 'gcloud.dart';

const _defaultName = 'rules-dart-linux-test';
const _machineType = 'e2-standard-4';
const _imageFamily = 'ubuntu-2204-lts';
const _imageProject = 'ubuntu-os-cloud';

const _startupScript = r'''#!/bin/bash
set -ex
# A failed step leaves its own mark, so the wait below stops at once rather
# than running out its deadline.
trap 'echo STARTUP_FAILED > /tmp/startup_complete' ERR

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# build-essential: C/C++ toolchain for cc_shared_library (sqlite3 code asset).
# zip/unzip/curl/git: Bazel + repository-rule basics.
apt-get install -y -qq \
  build-essential \
  zip \
  unzip \
  curl \
  git \
  python3

# Bazel via bazelisk (honours .bazelversion in each workspace).
if ! command -v bazel &>/dev/null; then
  curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
  chmod +x /usr/local/bin/bazel
fi

echo "STARTUP_COMPLETE" > /tmp/startup_complete
''';

Future<void> main(List<String> args) async {
  final vmName = args.isNotEmpty ? args[0] : _defaultName;
  final project = await getProject();
  final zone = await getZone();

  print('Creating Linux VM: $vmName');
  print('  Project: $project');
  print('  Zone: $zone');
  print('  Machine type: $_machineType');
  print('  Image: $_imageFamily ($_imageProject)');
  print('  Provisioning: SPOT (self-deletes on termination)');
  print('');

  // From a file: `--metadata` splits its value on commas, and the script
  // has them.
  final tmpDir = Directory.systemTemp.createTempSync('linux_vm_');
  final tmpStartup = File('${tmpDir.path}/startup.sh')
    ..writeAsStringSync(_startupScript);
  try {
    await gcloud([
      'compute',
      'instances',
      'create',
      vmName,
      '--machine-type=$_machineType',
      '--image-family=$_imageFamily',
      '--image-project=$_imageProject',
      '--provisioning-model=SPOT',
      '--instance-termination-action=DELETE',
      '--boot-disk-size=50GB',
      '--metadata-from-file=startup-script=${tmpStartup.path}',
      '--scopes=default',
    ]);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  print('');
  print('VM created. Waiting for SSH ...');
  await waitForSsh(vmName);

  print('Waiting for startup script (toolchain install) to complete ...');
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (true) {
    final r = await sshExec(vmName, 'cat /tmp/startup_complete 2>/dev/null');
    final mark = r.stdout.toString();
    if (mark.contains('STARTUP_COMPLETE')) break;
    if (mark.contains('STARTUP_FAILED') || DateTime.now().isAfter(deadline)) {
      stderr.writeln(
        'The startup script did not finish. Its log: gcloud compute ssh '
        "$vmName --command 'sudo journalctl -u google-startup-scripts'",
      );
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }

  print('');
  print('Linux VM ready: $vmName');
  print('');
  print('Next:');
  print('  dart run tools/vm/run_e2e.dart $vmName');
  print('  gcloud compute instances delete $vmName --quiet   # when done');
}
