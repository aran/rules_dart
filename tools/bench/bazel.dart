/// Runs Bazel in one of the bench's workspaces, with its own output base.
library;

import 'dart:io';

import 'load.dart';
import 'metrics.dart';
import 'report.dart';

/// Flags every build, test and run command gets: plain output, and no disk
/// cache, so a cold build runs every action. A cache another rc file still
/// turns on shows as cache hits, which the bench reports.
const _quiet = [
  '--noshow_progress',
  '--curses=no',
  '--color=no',
  '--show_result=0',
  '--disk_cache=',
];

class Bazel {
  Bazel({
    required this.workspace,
    required this.outputBase,
    required this.eventsDir,
    required this.profilesDir,
    required this.log,
    required this.ownOutputBases,
  });

  final String workspace;
  final String outputBase;
  final String eventsDir;
  final String profilesDir;

  /// Where every command's output goes; the bench prints its tail on failure.
  final File log;
  final List<String> ownOutputBases;

  /// The environment `bazel run` gave the bench, without what would point a
  /// nested Bazel at the bench's own runfiles or workspace.
  static final Map<String, String> _environment = {
    for (final e in Platform.environment.entries)
      if (!const {
        'RUNFILES_DIR',
        'RUNFILES_MANIFEST_FILE',
        'JAVA_RUNFILES',
        'BUILD_WORKSPACE_DIRECTORY',
        'BUILD_WORKING_DIRECTORY',
      }.contains(e.key))
        e.key: e.value,
  };

  List<String> _command(String verb, List<String> args) => [
    '--output_base=$outputBase',
    verb,
    if (const {'build', 'test', 'run', 'query'}.contains(verb)) ...[
      if (verb == 'query') ...[
        '--noshow_progress',
        '--color=no',
      ] else
        ..._quiet,
    ],
    ...args,
  ];

  Future<ProcessResult> _run(List<String> command) async {
    log.writeAsStringSync(
      '\n\$ bazel ${command.join(' ')}\n',
      mode: FileMode.append,
    );
    final result = await Process.run(
      'bazel',
      command,
      workingDirectory: workspace,
      environment: _environment,
      includeParentEnvironment: false,
    );
    log.writeAsStringSync(
      '${result.stdout}${result.stderr}',
      mode: FileMode.append,
    );
    return result;
  }

  /// Runs `bazel <verb> <args>`, unmeasured, and returns its stdout. Fails
  /// the bench when the command fails.
  Future<String> run(String verb, List<String> args) async {
    final result = await _run(_command(verb, args));
    if (result.exitCode != 0) {
      throw BenchFailure(
        '`bazel $verb ${args.join(' ')}` in $workspace exited '
        '${result.exitCode}; see ${log.path}:\n${_tail(result.stderr as String)}',
      );
    }
    return result.stdout as String;
  }

  /// Runs `bazel <verb> <args>` and records what it cost under [label].
  Future<Run> measure(String label, String verb, List<String> args) async {
    final events = '$eventsDir/$label.json';
    final profile = '$profilesDir/$label.profile.gz';
    final before = await otherServerCpu(ownOutputBases);
    final watch = Stopwatch()..start();
    final result = await _run(
      _command(verb, [
        '--keep_going',
        '--build_event_json_file=$events',
        '--profile=$profile',
        ...args,
      ]),
    );
    watch.stop();
    final after = await otherServerCpu(ownOutputBases);
    final eventsFile = File(events);
    return Run(
      parseBuildEvents(
        eventsFile.existsSync() ? eventsFile.readAsLinesSync() : const [],
        wallMs: watch.elapsedMilliseconds,
        exitCode: result.exitCode,
        profile: File(profile).existsSync() ? profile : null,
      ),
      otherServersCpuSeconds: cpuBetween(before, after),
    );
  }

  /// `bazel clean` then `bazel shutdown`: no outputs, no action cache, no
  /// analysis cache and no persistent workers. Fetched repositories stay.
  Future<void> coldStart() async {
    await run('clean', const []);
    await shutdown();
  }

  /// Stops the server, if the workspace has been set up.
  Future<void> shutdown() async {
    if (!Directory(workspace).existsSync()) return;
    await _run(['--output_base=$outputBase', 'shutdown']);
  }
}

String _tail(String text) {
  final lines = text.trimRight().split('\n');
  return lines.skip(lines.length > 30 ? lines.length - 30 : 0).join('\n');
}

/// A setup step or command the bench needs failed; the run cannot go on.
class BenchFailure implements Exception {
  BenchFailure(this.message);
  final String message;

  @override
  String toString() => message;
}
