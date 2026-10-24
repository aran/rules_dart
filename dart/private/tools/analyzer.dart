// What the analyze and fix runners need of the SDK's analyzer: `dart analyze`
// and `dart fix --apply`, run over a staged project in a build action.
//
// Two implementations behave alike, and `Analyzer.new` picks one.
// `DartCli` runs the plain commands; the runners pass `--dart-cli` unless
// `--@rules_dart//dart:analysis_shutdown_workaround` is on, which selects
// `ServerAnalyzer`, a workaround for a hang seen on macOS.
import 'dart_cli.dart';
import 'server_analyzer.dart';

/// What a command printed, and its exit code.
typedef Output = ({int exitCode, String stdout, String stderr});

/// `dart analyze` and `dart fix --apply`, as a build action runs them.
abstract interface class Analyzer {
  /// The analyzer of the SDK whose `dart` is [dart], caching in [cache].
  ///
  /// [DartCli] runs the commands themselves. [ServerAnalyzer], unless
  /// [dartCli], drives the analysis server they start, because on macOS the
  /// server's shutdown was seen to block forever and the commands report, or
  /// write, only after it (see `analysis_server.dart`).
  ///
  /// [cache] is emptied first and removed when a command ends. Beside the
  /// action's output, it goes with the sandbox, and an action Bazel cancels
  /// first leaves it for the action's next run to clear.
  factory Analyzer(
    String dart, {
    required String cache,
    required bool dartCli,
  }) => dartCli
      ? DartCli(dart, cache: cache)
      : ServerAnalyzer(dart, cache: cache);

  /// Analyzes [project] as `dart analyze [--fatal-infos] <project>` does,
  /// naming files inside [project] relative to it.
  Future<Output> analyze(String project, {required bool fatalInfos});

  /// Fixes the project at [root] in place, as `dart fix --apply <root>` does.
  Future<Output> fix(String root);
}
