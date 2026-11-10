// Build-action runner for `dart analyze` over a staged project directory.
//
// Analysis produces no output artifact, but a Bazel action must; this runner
// forwards the analyzer's diagnostics and writes the stamp file only on
// success. Pure Dart (no shell) so the action is portable to Windows. It also
// serves as a persistent worker (see `runAnalysisAction`).
import 'dart:io';

import 'analyzer.dart';

Future<void> main(List<String> args) => runAnalysisAction(args, analyze);

/// One analysis action: its [args] are the runner's.
Future<Result> analyze(List<String> args, Analyzers analyzers) async {
  String? dart;
  String? host;
  String? project;
  String? stamp;
  var fatalInfos = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--host':
        host = args[++i];
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--fatal-infos':
        fatalInfos = true;
      default:
        return (
          exitCode: 64,
          output: 'analyze_runner: unknown argument ${args[i]}\n',
        );
    }
  }
  if (dart == null || project == null || stamp == null) {
    return (
      exitCode: 64,
      output: 'analyze_runner: --dart, --project, and --stamp are required\n',
    );
  }

  final result = await analyzers(
    host: host,
    cache: '$stamp.cache',
  ).analyze(dart, project, fatalInfos: fatalInfos);
  // Bazel echoes any action output, so a clean run stays silent rather than
  // printing the analyzer's "No issues found!" on every build.
  final output = unstage(result.stderr, project);
  if (result.exitCode != 0) {
    return (
      exitCode: result.exitCode,
      output: output + unstage(result.stdout, project),
    );
  }
  File(stamp).writeAsStringSync('analyzed\n');
  return (exitCode: 0, output: output);
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
