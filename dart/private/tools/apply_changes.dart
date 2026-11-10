// `bazel run @rules_dart//dart/format` and `bazel run @rules_dart//dart/fix`:
// build the `dart_analyze` aspect's changes over target patterns, and write
// them into the workspace.
//
//   bazel run @rules_dart//dart/format -- --config=deep -- //app/... -//app/legacy/...
//   bazel run @rules_dart//dart/fix -- --dry-run $(bazel query 'kind(dart_library, //app/...)')
//
// The arguments after `--dry-run` are `bazel build`'s (`apply_args.dart`).
// The changes are what the aspect computes under `bazel test`: the format
// check fails on the very file this writes from. They come from a `bazel
// build` this tool runs, with the aspect and the one output group, and are
// located through that build's event file (`--build_event_json_file`), the
// interface Bazel offers for "which files did this build make". Each records
// the digest of the bytes it was computed from, and nothing is written if any
// file no longer holds them.
import 'dart:convert';
import 'dart:io';

import 'apply_args.dart';
import 'changes.dart';

const _usage =
    'usage: bazel run @rules_dart//dart/<format|fix> -- [--dry-run] '
    '<bazel build arguments>';

/// Names this tool in its messages: `dart format`, `dart fix`.
var _name = 'apply_changes';

Future<void> main(List<String> arguments) async {
  final ApplyArgs args;
  try {
    args = parseArgs(arguments);
  } on UsageException catch (e) {
    if (e.command case final command?) _name = 'dart $command';
    _fail('${e.message}\n$_usage', 64);
  }
  final command = args.command;
  _name = 'dart $command';

  // Set only under `bazel run`. Without them there is no source tree to write
  // into, and guessing one from the current directory could rewrite another.
  final env = Platform.environment;
  final workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  final working = env['BUILD_WORKING_DIRECTORY'];
  if (workspace == null || working == null) {
    _fail('run with `bazel run @rules_dart//dart/$command`', 1);
  }

  final scratch = Directory.systemTemp.createTempSync('dart_$command.');
  try {
    exitCode = await _run(
      scratch.path,
      args,
      working: working,
      workspace: workspace,
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

Future<int> _run(
  String scratch,
  ApplyArgs args, {
  required String working,
  required String workspace,
}) async {
  final ApplyArgs(:command, :group, :dryRun) = args;
  try {
    final events = '$scratch${Platform.pathSeparator}events.json';
    // From the directory `bazel run` was invoked in, so relative patterns
    // mean what they would on the user's own command line.
    final build = await Process.start(
      'bazel',
      args.buildArgs(events),
      workingDirectory: working,
      mode: ProcessStartMode.inheritStdio,
    );
    final built = await build.exitCode;
    if (built != 0) {
      stderr.writeln('$_name: the build failed, so nothing was written');
      return built;
    }

    final (:configured, :files) = _groupFiles(events, group);
    if (configured == 0) {
      // `bazel build` itself succeeds here, with "Found 0 targets".
      stderr.writeln(
        '$_name: the build left out every target, so nothing was written. '
        'A pattern can match nothing, and a named target is left out too '
        'when flags such as --build_tag_filters exclude it; pass the flags '
        'that build it: bazel run @rules_dart//dart/$command -- '
        '--config=<config> <pattern>',
      );
      return 1;
    }
    final sets = [for (final file in files) ChangeSet.read(file)];
    if (sets.isEmpty) {
      stderr.writeln(
        '$_name: none of the targets has Dart sources of its own to $command. '
        'Name Dart targets of this repository.',
      );
      return 1;
    }
    final code = applyChanges(
      sets,
      workspace: workspace,
      dryRun: dryRun,
      verb: command == 'fix' ? 'fixed' : 'formatted',
      out: stdout,
      err: stderr,
    );
    if (command == 'fix' &&
        !dryRun &&
        code == 0 &&
        sets.any((s) => s.changes.isNotEmpty)) {
      // One pass can expose fixes the analyzer could not offer before, so
      // only a run that writes nothing is done.
      stdout.writeln('Fixes can enable more fixes: run again until none are.');
    }
    return code;
  } on FormatException catch (e) {
    stderr.writeln('$_name: ${e.message}');
    return 1;
  }
}

/// The files of the aspect's output [group], by the build event file at
/// [events], and how many targets the build configured.
///
/// An aspect's completion event for a target lists its output groups by file
/// set, file sets nest, and each file is named relative to the exec root the
/// build's workspace event gives. The event names the aspect by the file that
/// defines it, not the one it was requested through, so the group, which only
/// `dart_analyze` makes, is what picks the events.
({int configured, List<String> files}) _groupFiles(
  String events,
  String group,
) {
  final sets = <String, Map<String, dynamic>>{};
  final roots = <String>[];
  var configured = 0;
  String? execRoot;
  for (final line in File(events).readAsLinesSync()) {
    if (line.isEmpty) continue;
    final event = jsonDecode(line) as Map<String, dynamic>;
    final id = event['id'] as Map<String, dynamic>;
    if (id['namedSet'] case {'id': final String setId}) {
      sets[setId] = event['namedSetOfFiles'] as Map<String, dynamic>;
    } else if (event['workspaceInfo'] case {
      'localExecRoot': final String root,
    }) {
      execRoot = root;
    } else if (id.containsKey('targetConfigured')) {
      configured++;
    } else if (id['targetCompleted'] case {'aspect': String _}) {
      final completed = event['completed'] as Map<String, dynamic>?;
      for (final g in (completed?['outputGroup'] as List? ?? const [])) {
        if (g['name'] != group) continue;
        for (final s in (g['fileSets'] as List? ?? const [])) {
          roots.add(s['id'] as String);
        }
      }
    }
  }
  if (execRoot == null) {
    throw FormatException('$events names no exec root');
  }

  final files = <String>{};
  final seen = <String>{};
  final pending = [...roots];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!seen.add(id)) continue;
    final set = sets[id];
    if (set == null) throw FormatException('$events lacks file set $id');
    for (final f in (set['files'] as List? ?? const [])) {
      final parts = [
        execRoot,
        ...(f['pathPrefix'] as List? ?? const []).cast<String>(),
        ...(f['name'] as String).split('/'),
      ];
      files.add(parts.join(Platform.pathSeparator));
    }
    for (final s in (set['fileSets'] as List? ?? const [])) {
      pending.add(s['id'] as String);
    }
  }
  for (final file in files) {
    if (!File(file).existsSync()) {
      // Left remote, as `--remote_download_outputs=minimal` does with
      // every output.
      throw FormatException(
        'the build made $file but did not download it; pass '
        '--remote_download_outputs=toplevel',
      );
    }
  }
  return (configured: configured, files: files.toList()..sort());
}

Never _fail(String message, int code) {
  stderr.writeln('$_name: $message');
  exit(code);
}
