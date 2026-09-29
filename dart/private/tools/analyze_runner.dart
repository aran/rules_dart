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
    stderr.writeln(
      'analyze_runner: --dart, --project, and --stamp are required',
    );
    exit(64);
  }

  final result = Process.runSync(dart, [
    'analyze',
    if (fatalInfos) '--fatal-infos',
    project,
  ]);
  // Bazel echoes any action output, so a clean run stays silent rather than
  // printing the analyzer's "No issues found!" on every build.
  stderr.write(unstage(result.stderr as String, project));
  if (result.exitCode != 0) {
    stdout.write(unstage(result.stdout as String, project));
    exit(result.exitCode);
  }
  File(stamp).writeAsStringSync('analyzed\n');
}

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — and quotes
/// absolute paths inside some messages (an unresolvable `include:` names the
/// options file that holds it). Both forms lose their staging prefix. Only the
/// `src/` tree is rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) {
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  return out
      .replaceAll('$absolute/src/', '')
      .replaceAllMapped(_diagnosticPath, (m) => m[1]!);
}

/// A diagnostic line's leading severity, up to its project-relative path.
final _diagnosticPath = RegExp(r'^(\s*\w+ - )src/', multiLine: true);
