// The analyzer that `--@rules_dart//dart:analysis_summaries` runs: the
// `package:analyzer` and linter of the SDK release it is built for, unpatched,
// reading each dependency from the summary its own action wrote rather than
// from its source.
//
//   summary_analyzer sdk-summary --sdk <dir> --out <file>
//   summary_analyzer summarize --project <dir> --sdk-summary <file>
//       [--summary <file>]... --out <file>
//   summary_analyzer analyze --project <dir> --sdk-summary <file>
//       [--summary <file>]... --stamp <file> [--fatal-infos]
//
// Arguments may come in an `@file`, one per line. With `--persistent_worker`,
// it serves Bazel's worker protocol, every request a command line of its own
// and a fresh analysis context: one request can never see another's files.
import 'dart:async';
import 'dart:io';

import 'package:bazel_worker/bazel_worker.dart';

import 'summary_analyzer/analyze.dart';
import 'summary_analyzer/args.dart';
import 'summary_analyzer/summarize.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--persistent_worker')) {
    await _Worker().run();
    exit(0);
  }
  final result = await run(expandFlagfiles(args));
  stderr.write(result.output);
  exit(result.exitCode);
}

/// Runs one command line.
///
/// An error the analyzer throws where nothing awaits it (its scheduler's own
/// work) fails the command too, rather than the process or a later request.
Future<Result> run(List<String> args) {
  final done = Completer<Result>();
  runZonedGuarded(
    () async {
      final result = await _run(args);
      if (!done.isCompleted) done.complete(result);
    },
    (e, stack) {
      if (done.isCompleted) return;
      done.complete((exitCode: 1, output: '${crashed(e, stack)}\n$turnOff'));
    },
  );
  return done.future;
}

Future<Result> _run(List<String> args) async {
  if (args.isEmpty) return usage('no command');
  final Args parsed;
  try {
    parsed = Args.parse(args.skip(1));
  } on ArgsException catch (e) {
    return usage(e.message);
  }
  try {
    return switch (args.first) {
      'sdk-summary' => await sdkSummary(parsed),
      'summarize' => await summarize(parsed),
      'analyze' => await analyze(parsed),
      final other => usage('unknown command `$other`'),
    };
  } on ArgsException catch (e) {
    return usage(e.message);
  } catch (e, stack) {
    return (exitCode: 1, output: 'summary_analyzer: $e\n$stack\n$turnOff');
  }
}

class _Worker extends AsyncWorkerLoop {
  final _home = Directory.current.path;

  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final sandbox = request.sandboxDir;
    Directory.current = sandbox.isEmpty
        ? _home
        : Directory(sandbox).isAbsolute
        ? sandbox
        : '$_home/$sandbox';
    final result = await run(expandFlagfiles(request.arguments));
    return WorkResponse(exitCode: result.exitCode, output: result.output);
  }
}
