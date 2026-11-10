// `Analyzer` by running `dart analyze` and `dart fix` themselves.
import 'dart:io';

import 'analyzer.dart';

/// Runs the SDK's `dart analyze` and `dart fix --apply`.
class DartCli implements Analyzer {
  /// Runs them caching in [cache], which is emptied first and removed when
  /// a command ends.
  DartCli({required String cache}) : _cache = Directory(cache);

  final Directory _cache;

  @override
  Future<Output> analyze(
    String dart,
    String project, {
    required bool fatalInfos,
  }) => _run(dart, [
    'analyze',
    if (fatalInfos) '--fatal-infos',
    '--cache=${_cache.absolute.path}',
    project,
  ]);

  // `dart fix` has no `--cache`: its server caches under the home directory,
  // so the home is the cache.
  @override
  Future<Output> fix(String dart, String root) => _run(
    dart,
    ['fix', '--apply', root],
    environment: {
      Platform.isWindows ? 'LOCALAPPDATA' : 'HOME': _cache.absolute.path,
    },
  );

  Future<Output> _run(
    String dart,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (_cache.existsSync()) _cache.deleteSync(recursive: true);
    _cache.createSync(recursive: true);
    try {
      final result = await Process.run(dart, args, environment: environment);
      return (
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } finally {
      try {
        _cache.deleteSync(recursive: true);
      } on FileSystemException {
        // A file the server held open on Windows: the next run clears it.
      }
    }
  }
}
