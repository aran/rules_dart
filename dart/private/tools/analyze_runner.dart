// Build-action runner for `dart analyze` over a staged project directory.
//
// Analysis produces no output artifact, but a Bazel action must; this runner
// forwards the analyzer's diagnostics and writes the stamp file only on
// success. Pure Dart (no shell) so the action is portable to Windows.
import 'dart:io';

import 'analyzer.dart';

Future<void> main(List<String> args) async {
  String? dart;
  String? project;
  String? stamp;
  var fatalInfos = false;
  var dartCli = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart-cli':
        dartCli = true;
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

  final result = await Analyzer(
    dart,
    cache: '$stamp.cache',
    dartCli: dartCli,
  ).analyze(project, fatalInfos: fatalInfos);
  // Bazel echoes any action output, so a clean run stays silent rather than
  // printing the analyzer's "No issues found!" on every build.
  stderr.write(unstage(result.stderr, project));
  if (result.exitCode != 0) {
    stdout.write(unstage(result.stdout, project));
    exit(result.exitCode);
  }
  File(stamp).writeAsStringSync('analyzed\n');
}

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — both where a
/// diagnostic is and where its context messages point, and quotes absolute
/// paths inside some messages (an unresolvable `include:` names the options
/// file that holds it). All lose their staging prefix. Only the `src/` tree is
/// rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) {
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  return out
      .replaceAll('$absolute/src/', '')
      .replaceAllMapped(_stagedPath, (m) => m[1]!);
}

/// A diagnostic line's leading severity, or a context message's text, up to
/// its project-relative path.
final _stagedPath = RegExp(
  r'^(\s*\w+ - |\s+- .* at )src[/\\]',
  multiLine: true,
);
