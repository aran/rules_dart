// Property: `bazel run @rules_dart//dart` writes nothing into the user's home.
// Bazel's build actions suppress Dart's telemetry; a run is not an action, so
// the launcher has to do it for the SDK it starts.
//
// The launcher runs with a throwaway HOME and no Dart telemetry variables, as
// they are in a user's shell; the home must be empty afterwards.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final r = Runfiles.create();
  final sdkBinary = r.rlocation(args[0]);

  late Directory home;
  late Directory workspace;
  setUp(() {
    home = Directory.systemTemp.createTempSync('home.');
    workspace = Directory.systemTemp.createTempSync('ws.');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  Map<String, String> userEnvironment() => {
    'HOME': home.path,
    'USERPROFILE': home.path,
    'APPDATA': '${home.path}/AppData',
    'LOCALAPPDATA': '${home.path}/AppData',
    'XDG_CONFIG_HOME': '${home.path}/.config',
    'BUILD_WORKSPACE_DIRECTORY': workspace.path,
    'BUILD_WORKING_DIRECTORY': workspace.path,
  };

  List<String> leftInHome() => [
    for (final e in home.listSync(recursive: true))
      e.path.substring(home.path.length),
  ];

  ProcessResult run(String exe, List<String> arguments) => Process.runSync(
    exe,
    arguments,
    environment: userEnvironment(),
    // The runfiles variables stay, as under `bazel run`; the home is the user's.
    includeParentEnvironment: true,
  );

  test('bazel run @rules_dart//dart leaves the home empty', () {
    // `--version` alone is not enough to be sure: `dart info` and `format`
    // are among the commands that reach the analytics client.
    for (final command in [
      ['--version'],
      ['info'],
      ['format', '--help'],
    ]) {
      final result = run(sdkBinary, command);
      expect(
        result.exitCode,
        0,
        reason: '${command.join(' ')}: ${result.stdout}${result.stderr}',
      );
    }
    expect(leftInHome(), isEmpty);
  });
}
