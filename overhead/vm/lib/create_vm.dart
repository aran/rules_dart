/// Creates the SPOT Linux and Windows VMs the e2e suites run on (`e2e.dart`).
///
/// Each gets what building with Bazel needs: a C/C++ toolchain, git, and
/// bazelisk, which reads each workspace's `.bazelversion`. No Dart SDK: the
/// rules fetch theirs. A repository that needs more on its VMs passes a
/// [LinuxVm] or [WindowsVm] with its additions to [createLinuxVm] or
/// [createWindowsVm] from a `dart_binary` of its own; the rest run
/// `@overhead//vm:create_linux_vm` and `@overhead//vm:create_windows_vm`.
///
/// Both return once the VM has finished its startup script, or exit non-zero
/// naming the step it stopped at.
library;

import 'dart:io';

import 'gcloud.dart';

/// The command line both creators take: `[vm-name] [--machine-type=<type>]
/// [--disk-size=<size>]`.
final class CreateArgs {
  CreateArgs(this.name, this.machineType, this.diskSize);

  /// Parses [args], defaulting what they leave out. Throws [FormatException].
  factory CreateArgs.parse(
    List<String> args, {
    required String defaultName,
    required String defaultMachineType,
    required String defaultDiskSize,
  }) {
    final positional = <String>[];
    var machineType = defaultMachineType;
    var diskSize = defaultDiskSize;
    for (final arg in args) {
      if (arg.startsWith('--machine-type=')) {
        machineType = arg.substring('--machine-type='.length);
      } else if (arg.startsWith('--disk-size=')) {
        diskSize = arg.substring('--disk-size='.length);
      } else if (arg.startsWith('-')) {
        throw FormatException('unknown option $arg');
      } else {
        positional.add(arg);
      }
    }
    if (positional.length > 1) {
      throw FormatException('one VM name, not ${positional.join(' ')}');
    }
    return CreateArgs(
      positional.isEmpty ? defaultName : positional.single,
      machineType,
      diskSize,
    );
  }

  final String name;
  final String machineType;
  final String diskSize;
}

/// What a Linux VM is, beyond the defaults.
final class LinuxVm {
  const LinuxVm({
    this.defaultName = 'e2e-linux',
    this.machineType = 'e2-standard-4',
    this.diskSize = '60GB',
    this.aptPackages = const [],
    this.startup = '',
  });

  final String defaultName;

  /// The default machine type; `--machine-type=` overrides it.
  final String machineType;

  /// The default boot disk size; `--disk-size=` overrides it.
  final String diskSize;

  /// Ubuntu packages to install besides the build basics.
  final List<String> aptPackages;

  /// Bash run as root after the basics are installed (`set -e` holds).
  final String startup;
}

/// Ubuntu 24.04, the image GitHub's `ubuntu-latest` runner has, so facts a
/// build resolves from its host match CI's.
const linuxImageFamily = 'ubuntu-2404-lts-amd64';
const _linuxImageProject = 'ubuntu-os-cloud';

/// The Linux startup script for [vm].
String linuxStartupScript(LinuxVm vm) =>
    '''
#!/bin/bash
set -ex
# A failed step leaves its own mark, so the wait stops at once rather than
# running out its deadline.
trap 'echo STARTUP_FAILED > /tmp/startup_complete' ERR

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# build-essential: the C/C++ toolchain for cc rules. zip, unzip, curl, git,
# python3: what Bazel and repository rules expect of a host.
apt-get install -y -qq build-essential zip unzip curl git python3 ${vm.aptPackages.join(' ')}

# bazelisk, as bazel: it runs the version each workspace's .bazelversion names.
if ! command -v bazel &>/dev/null; then
  curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
  chmod +x /usr/local/bin/bazel
fi

${vm.startup}

echo STARTUP_COMPLETE > /tmp/startup_complete
''';

/// Creates the Linux VM [args] describe and waits for its startup script.
Future<void> createLinuxVm(
  List<String> args, {
  LinuxVm vm = const LinuxVm(),
}) async {
  final CreateArgs parsed;
  try {
    parsed = CreateArgs.parse(
      args,
      defaultName: vm.defaultName,
      defaultMachineType: vm.machineType,
      defaultDiskSize: vm.diskSize,
    );
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\nUsage: create_linux_vm [vm-name] '
      '[--machine-type=${vm.machineType}] [--disk-size=${vm.diskSize}]',
    );
    exit(2);
  }
  final name = parsed.name;
  _describe(name, 'Linux', parsed, linuxImageFamily, await zone());

  // From a file: `--metadata` splits its value on commas, and the script has
  // them.
  final tmp = Directory.systemTemp.createTempSync('linux_vm_');
  try {
    final startup = File('${tmp.path}/startup.sh')
      ..writeAsStringSync(linuxStartupScript(vm));
    await gcloud([
      'compute',
      'instances',
      'create',
      name,
      ..._common(parsed, await zone()),
      '--image-family=$linuxImageFamily',
      '--image-project=$_linuxImageProject',
      '--metadata-from-file=startup-script=${startup.path}',
    ]);
  } finally {
    tmp.deleteSync(recursive: true);
  }

  await waitForSsh(name);
  stdout.writeln('Waiting for the startup script ...');
  final deadline = DateTime.now().add(const Duration(minutes: 10));
  while (true) {
    final r = await ssh(name, 'cat /tmp/startup_complete 2>/dev/null');
    final mark = r.stdout.toString();
    if (mark.contains('STARTUP_COMPLETE')) break;
    if (mark.contains('STARTUP_FAILED') || DateTime.now().isAfter(deadline)) {
      stderr.writeln(
        'The startup script did not finish. Its log: gcloud compute ssh '
        "$name --command 'sudo journalctl -u google-startup-scripts'",
      );
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  _ready(name);
}

/// What a Windows VM is, beyond the defaults.
final class WindowsVm {
  const WindowsVm({
    this.defaultName = 'e2e-windows',
    this.machineType = 'e2-standard-4',
    this.diskSize = '100GB',
    this.displayDevice = false,
    this.specialize = '',
    this.startup = '',
    this.defenderPaths = const [],
    this.defenderProcesses = const [],
  });

  final String defaultName;

  /// The default machine type; `--machine-type=` overrides it.
  final String machineType;

  /// The default boot disk size; `--disk-size=` overrides it.
  final String diskSize;

  /// Whether the VM has a virtual display device, for D3D rendering and
  /// screen capture.
  final bool displayDevice;

  /// PowerShell run once at first boot, during sysprep, after OpenSSH is
  /// installed: creating users, say.
  final String specialize;

  /// PowerShell run at every boot after the toolchain is installed and before
  /// the VM reports itself ready. It runs under [windowsStep], so it may
  /// call `Step "<what>" { ... }` to name what it is doing in
  /// `C:\startup_progress.txt` and fail the startup when a step fails.
  final String startup;

  /// Directories Defender's real-time scan skips, besides
  /// [windowsDefenderPaths].
  final List<String> defenderPaths;

  /// Processes whose file access Defender skips, besides
  /// [windowsDefenderProcesses].
  final List<String> defenderProcesses;
}

/// Where the e2e runner puts output bases, its disk cache, and checkouts on a
/// Windows VM, and the temporary directories builds write to: none of them
/// is scanned by Defender.
const windowsDefenderPaths = [
  r'C:\b',
  r'C:\bdc',
  r'C:\src',
  r'C:\temp',
  r'C:\Windows\Temp',
];

/// The processes a Bazel build of Dart and C++ runs most.
const windowsDefenderProcesses = [
  'java.exe',
  'bazel.exe',
  'dart.exe',
  'dartaotruntime.exe',
  'cl.exe',
  'link.exe',
];

const _windowsImageFamily = 'windows-2022';
const _windowsImageProject = 'windows-cloud';

/// Marks the Windows startup script leaves: `C:\startup_complete.txt` when it
/// finishes or fails, `C:\startup_progress.txt` with the step it is on.
const windowsStartupMarker = r'C:\startup_complete.txt';
const windowsStartupProgress = r'C:\startup_progress.txt';

/// The PowerShell `Step` function the startup script runs each step under:
/// it records the step in [windowsStartupProgress], and a step that throws or
/// whose last native command exits non-zero (other than 3010 and 1641, which
/// ask for a reboot) writes `STARTUP_FAILED: <step>` to [windowsStartupMarker]
/// and ends the script.
const windowsStep = r'''
function Step([string]$what, [scriptblock]$body) {
    Set-Content -Path 'C:\startup_progress.txt' -Value "$(Get-Date -Format o) $what"
    $global:LASTEXITCODE = 0
    try { & $body } catch {
        Set-Content -Path 'C:\startup_complete.txt' -Value "STARTUP_FAILED: $what`: $_"
        exit 1
    }
    if ($LASTEXITCODE -notin 0, 1641, 3010) {
        Set-Content -Path 'C:\startup_complete.txt' -Value "STARTUP_FAILED: $what (exit $LASTEXITCODE)"
        exit 1
    }
}
''';

/// The Windows sysprep script for [vm]. The `windows-2022` image ships no
/// OpenSSH, and `enable-windows-ssh=TRUE` only configures one already there,
/// so this installs Google's package; it is what makes `gcloud compute ssh`
/// work.
String windowsSpecializeScript(WindowsVm vm) =>
    '''
googet -noconfirm=true install google-compute-engine-ssh
${vm.specialize}
''';

/// The Windows startup script for [vm].
///
/// Chocolatey's community feed sometimes hangs a `choco install` (seen: git,
/// 43 minutes of CPU, nothing installed). Each install runs without its
/// progress bar, logs to a file rather than to the guest agent's pipe, and has
/// a 15-minute limit, tried twice, so a hang ends as `STARTUP_FAILED` naming
/// the package rather than as a VM that never becomes ready.
String windowsStartupScript(WindowsVm vm) {
  String quoted(List<String> items) => items.map((i) => "'$i'").join(',');
  return '''
\$ErrorActionPreference = "Stop"
$windowsStep
# Not named `choco`: PowerShell runs a function before a command of its name,
# so its `choco install` would call itself.
function Install-ChocoPackage([string]\$package, [string[]]\$more = @()) {
    Step "choco install \$package" {
        # Windows PowerShell turns a redirected native stderr line into an
        # error, which "Stop" would make fatal.
        \$ErrorActionPreference = "Continue"
        foreach (\$try in 1, 2) {
            choco install -y --no-progress --execution-timeout=900 \$package @more *>> C:\\choco_install.log
            if (\$LASTEXITCODE -in 0, 1641, 3010) { break }
        }
    }
}

# Before anything builds: Defender's scan of a build's tens of thousands of
# small files takes most of a core.
Step "Defender exclusions" {
    Add-MpPreference -ExclusionPath ${quoted([...windowsDefenderPaths, ...vm.defenderPaths])}
    Add-MpPreference -ExclusionProcess ${quoted([...windowsDefenderProcesses, ...vm.defenderProcesses])}
}

# Win32 long paths, for Bazel's deep output trees.
Step "long paths" {
    Set-ItemProperty -Path "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem" -Name LongPathsEnabled -Value 1 -Type DWord -Force
}

Step "install Chocolatey" {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
}

# Git without its Unix tools on PATH: their link.exe and find.exe shadow
# MSVC's and Windows', and break Bazel's C++ actions. Its bash is BAZEL_SH.
Install-ChocoPackage git
Install-ChocoPackage bazelisk
Install-ChocoPackage vcredist140
Install-ChocoPackage visualstudio2022buildtools @('--package-parameters', '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')

Step "Bazel environment" {
    [System.Environment]::SetEnvironmentVariable("BAZEL_VC", "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC", "Machine")
    # Bazel's test setup needs a bash; without one every test target fails
    # analysis with "No suitable shell toolchain found".
    [System.Environment]::SetEnvironmentVariable("BAZEL_SH", "C:\\Program Files\\Git\\usr\\bin\\bash.exe", "Machine")
}

# Server Manager would take the foreground at every logon.
Step "disable Server Manager" {
    schtasks /Change /TN "\\Microsoft\\Windows\\Server Manager\\ServerManager" /DISABLE
}

${vm.startup}

Set-Content -Path '$windowsStartupMarker' -Value "STARTUP_COMPLETE"
''';
}

/// Creates the Windows VM [args] describe and waits for its startup script.
Future<void> createWindowsVm(
  List<String> args, {
  WindowsVm vm = const WindowsVm(),
}) async {
  final CreateArgs parsed;
  try {
    parsed = CreateArgs.parse(
      args,
      defaultName: vm.defaultName,
      defaultMachineType: vm.machineType,
      defaultDiskSize: vm.diskSize,
    );
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\nUsage: create_windows_vm [vm-name] '
      '[--machine-type=${vm.machineType}] [--disk-size=${vm.diskSize}]',
    );
    exit(2);
  }
  final name = parsed.name;
  _describe(name, 'Windows', parsed, _windowsImageFamily, await zone());

  final tmp = Directory.systemTemp.createTempSync('windows_vm_');
  try {
    final specialize = File('${tmp.path}/specialize.ps1')
      ..writeAsStringSync(windowsSpecializeScript(vm));
    final startup = File('${tmp.path}/startup.ps1')
      ..writeAsStringSync(windowsStartupScript(vm));
    await gcloud([
      'compute',
      'instances',
      'create',
      name,
      ..._common(parsed, await zone()),
      '--image-family=$_windowsImageFamily',
      '--image-project=$_windowsImageProject',
      if (vm.displayDevice) '--enable-display-device',
      '--metadata=enable-windows-ssh=TRUE',
      '--metadata-from-file=sysprep-specialize-script-ps1=${specialize.path},'
          'windows-startup-script-ps1=${startup.path}',
      // SSD: a Bazel build is tens of thousands of small file writes and
      // deletes; on a standard disk one build took 60+ minutes that took 9 on
      // an SSD.
      '--boot-disk-type=pd-ssd',
    ]);
  } finally {
    tmp.deleteSync(recursive: true);
  }

  // Sysprep, a reboot and the guest agent come before SSH; it has been seen
  // to take more than 25 minutes on a VM that was healthy soon after.
  await waitForSsh(name, timeout: const Duration(minutes: 30));
  stdout.writeln('Waiting for the startup script (about 15 minutes) ...');
  final reason = await waitForWindowsStartup(
    name,
    budget: const Duration(minutes: 30),
  );
  if (reason != null) {
    stderr.writeln(
      '$reason\nReplace the VM rather than wait: '
      'gcloud compute instances delete $name --quiet',
    );
    exit(1);
  }
  _ready(name);
}

/// Waits up to [budget] for a Windows VM's startup script, printing the step
/// it is on. Returns null when it finished, else why it did not.
Future<String?> waitForWindowsStartup(
  String vmName, {
  required Duration budget,
}) async {
  final deadline = DateTime.now().add(budget);
  var last = '';
  while (true) {
    final r = await ssh(
      vmName,
      'cmd /c "type $windowsStartupMarker & type $windowsStartupProgress"',
      quiet: true,
      timeout: const Duration(minutes: 2),
    );
    final out = r.stdout.toString();
    if (out.contains('STARTUP_COMPLETE')) return null;
    final failed = RegExp('STARTUP_FAILED[^\r\n]*').firstMatch(out);
    if (failed != null) return '$vmName: ${failed[0]}';
    final step = out.trim().split(RegExp(r'\r?\n')).last;
    if (step != last) stdout.writeln('  $step');
    last = step;
    if (DateTime.now().isAfter(deadline)) {
      return '$vmName: the startup script did not finish in $budget; '
          'it was at: $last';
    }
    await Future<void>.delayed(const Duration(seconds: 20));
  }
}

List<String> _common(CreateArgs args, String zone) => [
  '--zone=$zone',
  '--machine-type=${args.machineType}',
  '--boot-disk-size=${args.diskSize}',
  // SPOT costs a fraction of standard. The zone may reclaim the VM at any
  // time; DELETE then stops it costing anything, and takes its caches with
  // it, which the e2e runner's --remote-cache keeps.
  '--provisioning-model=SPOT',
  '--instance-termination-action=DELETE',
  // storage-rw: the e2e runner's --remote-cache, a bucket the VMs share.
  '--scopes=default,storage-rw',
];

void _describe(
  String name,
  String os,
  CreateArgs args,
  String image,
  String zone,
) {
  stdout
    ..writeln('Creating $os VM $name')
    ..writeln('  Zone: $zone')
    ..writeln('  Machine type: ${args.machineType}')
    ..writeln('  Boot disk: ${args.diskSize}')
    ..writeln('  Image: $image')
    ..writeln('  SPOT: deleted when preempted');
}

void _ready(String name) {
  stdout
    ..writeln('\n$name is ready. Delete it when done:')
    ..writeln('  gcloud compute instances delete $name --quiet');
}
