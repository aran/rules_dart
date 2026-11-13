import 'package:overhead_vm/create_vm.dart';
import 'package:test/test.dart';

void main() {
  CreateArgs parse(List<String> args) => CreateArgs.parse(
    args,
    defaultName: 'n',
    defaultMachineType: 'm',
    defaultDiskSize: 'd',
  );

  test('defaults', () {
    final a = parse([]);
    expect([a.name, a.machineType, a.diskSize], ['n', 'm', 'd']);
  });

  test('a name, machine type and disk size', () {
    final a = parse([
      '--disk-size=200GB',
      'vm',
      '--machine-type=n2-standard-16',
    ]);
    expect(
      [a.name, a.machineType, a.diskSize],
      ['vm', 'n2-standard-16', '200GB'],
    );
  });

  test('refuses an unknown option or two names', () {
    expect(() => parse(['--windows']), throwsFormatException);
    expect(() => parse(['a', 'b']), throwsFormatException);
  });

  test("the Linux script installs the repository's packages and runs its "
      'steps before it reports ready', () {
    final script = linuxStartupScript(
      const LinuxVm(aptPackages: ['xvfb', 'scrot'], startup: 'echo extra'),
    );
    expect(script, startsWith('#!/bin/bash\n'));
    expect(script, contains('python3 xvfb scrot\n'));
    expect(
      script.indexOf('echo extra'),
      lessThan(script.indexOf('echo STARTUP_COMPLETE')),
    );
  });

  test('the Windows script excludes both lists from Defender, and runs the '
      "repository's steps before it reports ready", () {
    final script = windowsStartupScript(
      const WindowsVm(
        defenderPaths: [r'C:\android'],
        defenderProcesses: ['aapt2.exe'],
        startup: 'Step "extra" { }',
      ),
    );
    expect(
      script,
      contains(
        r"-ExclusionPath 'C:\b','C:\bdc','C:\src','C:\temp','C:\Windows\Temp',"
        r"'C:\android'",
      ),
    );
    expect(script, contains("'link.exe','aapt2.exe'"));
    expect(script, contains('function Step('));
    expect(
      script.indexOf('Step "extra"'),
      lessThan(script.indexOf('STARTUP_COMPLETE')),
    );
    // Dart's interpolation leaves no `$name` of its own behind.
    expect(script, isNot(contains(r'${')));
    expect(script, contains(r'choco install -y --no-progress'));
  });

  test(
    "the Windows sysprep script installs OpenSSH, then the repository's",
    () {
      final script = windowsSpecializeScript(
        const WindowsVm(specialize: 'net user t p /add'),
      );
      expect(
        script.indexOf('google-compute-engine-ssh'),
        lessThan(script.indexOf('net user')),
      );
    },
  );
}
