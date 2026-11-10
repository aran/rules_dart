/// Creates a SPOT Windows VM for running the rules_dart e2e suites on Windows.
///
/// Usage: dart run tools/vm/create_windows_vm.dart [vm-name]
///
/// The VM gets MSVC Build Tools (for `cc_shared_library`, e.g. the sqlite3
/// code asset), `bazelisk`, and SSH. The Dart SDK is **not** installed —
/// rules_dart's toolchain fetches it hermetically. No RDP/display is needed;
/// everything runs over SSH.
///
/// The startup script installs the toolchain (~15 min). `run_e2e.dart` waits
/// for completion automatically. After creation:
///   `dart run tools/vm/run_e2e.dart <vm-name> --windows`
library;

import 'dart:io';

import 'gcloud.dart';

const _defaultName = 'rules-dart-windows-test';
const _machineType = 'e2-standard-4';
const _imageFamily = 'windows-2022';
const _imageProject = 'windows-cloud';

/// Sysprep specialize script — runs once on first boot, before the GCE guest
/// agent's account setup. Installs Google's OpenSSH package: the `windows-2022`
/// image ships no OpenSSH, and `enable-windows-ssh=TRUE` only *configures* SSH
/// if it is already present (otherwise the agent logs "could not find version"
/// and never comes up). This is what makes `gcloud compute ssh` work.
const _specializeScript = '''
googet -noconfirm=true install google-compute-engine-ssh
''';

/// PowerShell startup script — runs on every boot. Installs the toolchain,
/// keeps MSYS/Unix tools off the system PATH (they shadow MSVC's link.exe and
/// break Bazel on Windows), enables long paths, then signals completion.
const _startupScript = r'''
$ErrorActionPreference = "Stop"

# Enable Win32 long paths (Bazel + deep output trees).
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
  -Name LongPathsEnabled -Value 1 -Type DWord -Force

# Chocolatey.
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
      [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# git WITHOUT the Unix tools on PATH (avoids link.exe / find.exe shadowing).
choco install -y git
choco install -y bazelisk
choco install -y vcredist140
choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

# Point Bazel at the MSVC install.
[System.Environment]::SetEnvironmentVariable("BAZEL_VC", "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC", "Machine")

# Bazel on Windows needs a bash for its test infrastructure
# (collect_coverage). Point it at Git for Windows' bash; without this every
# test-bearing target fails analysis with "No suitable shell toolchain found".
[System.Environment]::SetEnvironmentVariable("BAZEL_SH", "C:\Program Files\Git\usr\bin\bash.exe", "Machine")

# Don't let Server Manager grab the foreground.
schtasks /Change /TN "\Microsoft\Windows\Server Manager\ServerManager" /DISABLE

New-Item -Path C:\startup_complete.txt -Value "STARTUP_COMPLETE" -Force
''';

Future<void> main(List<String> args) async {
  final vmName = args.isNotEmpty ? args[0] : _defaultName;
  final project = await getProject();
  final zone = await getZone();

  stdout.writeln('Creating Windows VM: $vmName');
  stdout.writeln('  Project: $project');
  stdout.writeln('  Zone: $zone');
  stdout.writeln('  Machine type: $_machineType');
  stdout.writeln('  Image: $_imageFamily ($_imageProject)');
  stdout.writeln('  Provisioning: SPOT (self-deletes on termination)');
  stdout.writeln('');

  final tmpDir = Directory.systemTemp.createTempSync('rd_win_vm_');
  final tmpSpecialize = File('${tmpDir.path}/specialize.ps1')
    ..writeAsStringSync(_specializeScript);
  final tmpStartup = File('${tmpDir.path}/startup.ps1')
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
      '--metadata=enable-windows-ssh=TRUE',
      '--metadata-from-file=sysprep-specialize-script-ps1=${tmpSpecialize.path},'
          'windows-startup-script-ps1=${tmpStartup.path}',
      '--scopes=default',
      '--boot-disk-size=100GB',
    ]);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  stdout.writeln('');
  stdout.writeln('VM created. Waiting for SSH ...');
  // Windows sysprep + reboot + agent bring-up can take a while before SSH
  // (installed via the specialize googet) accepts connections.
  await waitForSsh(vmName, timeout: const Duration(minutes: 25));

  stdout.writeln('');
  stdout.writeln('Windows VM created: $vmName');
  stdout.writeln('');
  stdout.writeln(
    'The startup script is installing the toolchain (Git, Bazel, MSVC).',
  );
  stdout.writeln(
    'This takes ~15 min; run_e2e.dart waits for it automatically.',
  );
  stdout.writeln('');
  stdout.writeln('Next:');
  stdout.writeln('  dart run tools/vm/run_e2e.dart $vmName --windows');
  stdout.writeln(
    '  gcloud compute instances delete $vmName --quiet   # when done',
  );
}
