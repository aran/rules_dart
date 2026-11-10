import 'dart:convert';
import 'dart:io';

/// Reads the configuration a rule wrote beside the executable it made from a
/// shared launcher: `<name>.launcher.json` beside `<name>` (or `<name>.exe`).
///
/// Beside the executable rather than in the environment, so that the target
/// runs the same however it is started: by `bazel run` or `bazel test`, which
/// would pass the environment, or as another target's `data`, which does not.
/// A link to the executable under another name (`platform_data`, say) is
/// followed until the configuration is found.
Map<String, dynamic> readLauncherConfig(String tool) {
  var path = Platform.executable;
  final tried = <String>[];
  for (var hops = 0; hops < 32; hops++) {
    final config = _configBeside(path);
    tried.add(config);
    if (File(config).existsSync()) {
      return jsonDecode(File(config).readAsStringSync())
          as Map<String, dynamic>;
    }
    if (!FileSystemEntity.isLinkSync(path)) break;
    final target = Link(path).targetSync();
    path = File(target).isAbsolute
        ? target
        : '${File(path).parent.path}${Platform.pathSeparator}$target';
  }
  stderr.writeln(
    '$tool: no launcher configuration beside ${Platform.executable}; '
    'looked for ${tried.join(', ')}',
  );
  exit(1);
}

String _configBeside(String executable) {
  final stem = executable.toLowerCase().endsWith('.exe')
      ? executable.substring(0, executable.length - 4)
      : executable;
  return '$stem.launcher.json';
}

/// The exit code that reports how [code], a child's exit code, ended: a
/// child killed by a signal (negative in `dart:io`) is reported as a shell
/// does, 128 plus the signal number.
int launcherExitCode(int code) => code < 0 ? 128 - code : code;
