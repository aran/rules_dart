// Build-action runner for `dart format` over a staged project directory.
//
// `dart format` produces no output artifact, but a Bazel action must; this
// runner forwards the formatter's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
//
// Files are named individually from a manifest rather than by handing the
// formatter the project directory. The staged project also holds the harness
// (stub pubspecs, package_config.json) and, when the options file pulls in a
// lint ruleset, that package's own sources — none of which are the target's to
// format.
import 'dart:convert';
import 'dart:io';

/// Characters of joined argv per `dart format` invocation. Windows caps a
/// command line near 32k; a staged path is long and a `srcs` glob can be
/// large, so the file list is split to stay well clear of it.
const _argvBudget = 8000;

void main(List<String> args) {
  String? dart;
  String? project;
  String? manifest;
  String? stamp;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--stamp':
        stamp = args[++i];
      default:
        stderr.writeln('format_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null || project == null || manifest == null || stamp == null) {
    stderr.writeln(
      'format_runner: --dart, --project, --manifest, and --stamp are required',
    );
    exit(64);
  }

  final files = File(manifest)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .map((l) => _join(project!, l))
      .toList();

  var failed = false;
  for (final chunk in _chunks(files)) {
    final result = Process.runSync(
      dart,
      ['format', '--output=none', '--set-exit-if-changed', ...chunk],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    // Reported at the path the user can act on. The formatter names the file
    // it was handed, which is inside the staged tree — an output path nobody
    // can edit, and one that buries the workspace path it was copied from.
    stdout.write(_unstage(result.stdout as String, project));
    stderr.write(_unstage(result.stderr as String, project));
    if (result.exitCode != 0) {
      failed = true;
    }

    // A malformed or unresolvable `include:` does not fail the formatter — it
    // warns on stderr, exits 0, and silently formats at stock defaults. That
    // is the same silent-wrong-verdict this rule exists to prevent, so the
    // warning is escalated: a check that quietly stopped honouring the
    // configured page width must not report green.
    if (_warned(result.stderr as String)) {
      stderr.writeln(
        'format_runner: `dart format` warned while reading analysis options, '
        'so the check would have run at stock defaults rather than the '
        'configured ones. Fix the options file named above.',
      );
      failed = true;
    }
  }

  if (failed) {
    exit(1);
  }
  File(stamp).writeAsStringSync('formatted\n');
}

/// Rewrites staged paths in the formatter's output back to the workspace paths
/// they were copied from, so a violation names a file the user can open.
String _unstage(String out, String project) =>
    out.replaceAll('${project.replaceAll(r'\', '/')}/src/', '');

/// Whether the formatter reported a non-fatal problem reading its options.
bool _warned(String err) =>
    const LineSplitter().convert(err).any((l) => l.startsWith('Warning:'));

/// Splits [files] into runs whose joined length fits [_argvBudget]. A single
/// path longer than the budget still gets its own invocation rather than being
/// dropped.
Iterable<List<String>> _chunks(List<String> files) sync* {
  var current = <String>[];
  var length = 0;
  for (final f in files) {
    if (current.isNotEmpty && length + f.length + 1 > _argvBudget) {
      yield current;
      current = <String>[];
      length = 0;
    }
    current.add(f);
    length += f.length + 1;
  }
  if (current.isNotEmpty) {
    yield current;
  }
}

/// Joins a project-relative manifest entry onto the staged project directory.
///
/// The result stays relative to the exec root, as `--project` is: the action
/// runs there, and the staged root's own `analysis_options.yaml` is nearer to
/// every one of these paths than anything above the project, so the
/// formatter's options walk-up terminates inside the staged tree either way.
String _join(String project, String relative) =>
    '${project.replaceAll(r'\', '/')}/$relative';
