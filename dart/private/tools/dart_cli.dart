// `Analyzer` by running `dart analyze` and `dart fix` themselves.
import 'dart:io';

import 'analyzer.dart';

/// Runs the SDK's `dart analyze` and `dart fix --apply`.
class DartCli implements Analyzer {
  DartCli(this._dart, {required String cache}) : _cache = Directory(cache);

  final String _dart;
  final Directory _cache;

  @override
  Future<Output> analyze(String project, {required bool fatalInfos}) => _run([
    'analyze',
    if (fatalInfos) '--fatal-infos',
    '--cache=${_cache.absolute.path}',
    project,
  ]);

  // `dart fix` has no `--cache`: its server caches under the home directory,
  // so the home is the cache.
  @override
  Future<Output> fix(String root) => _run(
    ['fix', '--apply', root],
    environment: {
      Platform.isWindows ? 'LOCALAPPDATA' : 'HOME': _cache.absolute.path,
    },
  );

  Future<Output> _run(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (_cache.existsSync()) _cache.deleteSync(recursive: true);
    _cache.createSync(recursive: true);
    try {
      final result = await Process.run(_dart, args, environment: environment);
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
