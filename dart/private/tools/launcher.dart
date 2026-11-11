// The executable of a `dart_binary` in the `kernel` and
// `aot-snapshot` modes, and of `@rules_dart//dart`: starts a program from the
// Dart SDK, with the user's arguments after the ones its rule fixed.
//
// What to start is in `<name>.launcher.json` beside the executable
// (`launcher_config.dart`):
//
//   executable         runfiles path of the program to start (`dart`,
//                      `dartaotruntime`)
//   arguments          its leading arguments, each a string or
//                      `{"rlocation": <runfiles path>, "prefix": <string>}`,
//                      the file's path after the optional prefix
//   environment        variables to add to the caller's
//   working_directory  `invocation` to start in the directory `bazel run`
//                      was invoked from; otherwise the launcher's own
//
// The program gets the caller's environment, these variables, and the
// runfiles variables, so that `package:runfiles` in a compiled program finds
// the runfiles that belong to this executable.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'launcher_config.dart';

Future<void> main(List<String> args) async {
  final config = readLauncherConfig('launcher');
  final r = Runfiles.create();
  String resolve(Object? entry) {
    if (entry is String) return entry;
    final file = entry as Map<String, dynamic>;
    return '${file['prefix'] ?? ''}${r.rlocation(file['rlocation'] as String)}';
  }

  String? workingDirectory;
  if (config['working_directory'] == 'invocation') {
    final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
    if (cwd != null && cwd.isNotEmpty) workingDirectory = cwd;
  }
  final process = await Process.start(
    r.rlocation(config['executable'] as String),
    [
      for (final argument in config['arguments'] as List<dynamic>)
        resolve(argument),
      ...args,
    ],
    workingDirectory: workingDirectory,
    environment: {
      ...r.environment,
      ...(config['environment'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    },
    mode: ProcessStartMode.inheritStdio,
  );
  exit(launcherExitCode(await process.exitCode));
}
