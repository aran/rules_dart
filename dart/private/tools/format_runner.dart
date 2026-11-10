// Build-action runner for the `dart_analyze` aspect's format check: `dart format`
// over a staged project directory, recording what it would change.
//
// The output is a changes file (`changes.dart`): the target's files the
// formatter would rewrite, with their new content. The check fails on a
// non-empty one (`format_check.dart`), and `bazel run
// @rules_dart//dart/format` writes it into the workspace, so the two cannot
// disagree. This action fails only when the formatter cannot run as
// configured. Pure Dart (no shell) so the action is portable to Windows.
//
// Files are named individually from a manifest rather than by handing the
// formatter the project directory. The staged project also holds the harness
// (stub pubspecs, package_config.json), the target's dependencies and any lint
// ruleset an options file pulls in — none of which are the target's to format.
import 'dart:convert';
import 'dart:io';

import 'changes.dart';

/// Characters of joined argv per `dart format` invocation. Windows caps a
/// command line near 32k; a staged path is long and a `srcs` glob can be
/// large, so the file list is split to stay well clear of it. The budget
/// covers the file list alone — the fixed flags in front of it are a few dozen
/// characters, and the margin to 32k absorbs them many times over.
const _argvBudget = 8000;

void main(List<String> args) {
  String? dart;
  String? project;
  String? manifest;
  String? changes;
  String? label;
  String? languageVersion;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--changes':
        changes = args[++i];
      case '--label':
        label = args[++i];
      case '--language-version':
        languageVersion = args[++i];
      default:
        stderr.writeln('format_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null ||
      project == null ||
      manifest == null ||
      changes == null ||
      label == null ||
      languageVersion == null) {
    stderr.writeln(
      'format_runner: --dart, --project, --manifest, --changes, --label and '
      '--language-version are required',
    );
    exit(64);
  }

  // Each line is the file's path in the staged project, `src/<workspace
  // path>`.
  final staged = File(manifest)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .toList();
  final byPath = {for (final s in staged) _join(project, s): s};

  final proposed = <Change>[];
  var failed = false;
  for (final chunk in _chunks(byPath.keys.toList())) {
    final result = Process.runSync(
      dart,
      [
        'format',
        '--output=json',
        // Passed in every case, `latest` included. The formatter would
        // otherwise take the version from whatever package_config.json entry
        // happens to cover the staged file, which for an entrypoint outside
        // `lib/` need not be the target's own. See dart_analyze_aspect.bzl.
        '--language-version=$languageVersion',
        ...chunk,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: systemEncoding,
    );
    // Reported at the path the user can act on. The formatter names the file
    // it was handed, which is inside the staged tree — an output path nobody
    // can edit, and one that buries the workspace path it was copied from.
    stderr.write(_unstage(result.stderr as String, project));
    if (result.exitCode != 0) {
      failed = true;
      continue;
    }

    // A malformed or unresolvable `include:` does not fail the formatter — it
    // warns on stderr, exits 0, and silently formats at stock defaults. Its
    // output would then be a rewrite to settings nobody configured, so the
    // warning is escalated rather than the output recorded.
    if (_warned(result.stderr as String)) {
      stderr.writeln(
        'format_runner: `dart format` warned while reading analysis options, '
        'so it would have formatted at stock defaults rather than the '
        'configured ones. Fix the options file named above.',
      );
      failed = true;
      continue;
    }

    // One JSON object a line, for every file it was given, changed or not.
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      if (line.isEmpty) continue;
      final json = jsonDecode(line) as Map<String, dynamic>;
      final path = json['path'] as String;
      final source = json['source'] as String;
      final stagedPath = byPath[path];
      if (stagedPath == null) {
        stderr.writeln(
          'format_runner: `dart format` reported $path, which it '
          'was not given',
        );
        exit(1);
      }
      final before = digest(File(path).readAsBytesSync());
      if (digest(utf8.encode(source)) == before) continue;
      proposed.add(
        Change(
          path: stagedPath.substring('src/'.length),
          sha256: before,
          content: source,
        ),
      );
    }
  }

  if (failed) {
    exit(1);
  }
  ChangeSet(target: label, changes: proposed).write(changes);
}

/// Rewrites staged source paths in the formatter's output back to the workspace
/// paths they were copied from, so a message names a file the user can open.
///
/// The formatter echoes the files it was handed as given — relative,
/// forward-slashed, as every Bazel exec path is — and names options files (an
/// `include:` it could not read) by absolute path. Both lose their whole
/// staging prefix, the absolute form first: stripping only the relative
/// project path from the middle of an absolute one would leave a path that
/// looks like the source tree's and names a file the formatter never read.
/// Only the `src/` tree is rewritten: nothing outside it has a workspace path.
String _unstage(String out, String project) {
  final relative = project.replaceAll(r'\', '/');
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  return out.replaceAll('$absolute/src/', '').replaceAll('$relative/src/', '');
}

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
