// Build-action runner for `dart analyze` over a staged project directory.
//
// `dart analyze` produces no output artifact, but a Bazel action must; this
// runner forwards the analyzer's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
import 'dart:io';

void main(List<String> args) {
  String? dart;
  String? project;
  String? stamp;
  var fatalInfos = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--fatal-infos':
        fatalInfos = true;
      default:
        stderr.writeln('analyze_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null || project == null || stamp == null) {
    stderr.writeln('analyze_runner: --dart, --project, and --stamp are required');
    exit(64);
  }

  final result = Process.runSync(dart, [
    'analyze',
    if (fatalInfos) '--fatal-infos',
    project,
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exit(result.exitCode);
  }
  File(stamp).writeAsStringSync('analyzed\n');
}
