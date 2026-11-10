// Checks commit messages against the commit policy in AGENTS.md: a
// conventional-commit subject, and the `Changelog:` trailer rules.
//
//   bazel run @overhead//changelog:check -- <message-file>          (commit-msg hook)
//   bazel run @overhead//changelog:check -- --push <before> <after>  (CI, on push)
//   bazel run @overhead//changelog:check -- --range <rev-range>      (by hand)
import 'dart:convert';
import 'dart:io';

import 'commit_policy.dart';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  if (args.length == 3 && args[0] == '--push') {
    final before = args[1], after = args[2];
    final range = pushRange(before, after, _hasCommit);
    exit(await _checkRange(range));
  }
  if (args.length == 2 && args[0] == '--range') {
    exit(await _checkRange(args[1]));
  }
  if (args.length == 1 && !args[0].startsWith('--')) {
    exit(await _checkFile(args[0]));
  }
  stderr.writeln(
    'usage: check (<message-file> | --push <before> <after> | '
    '--range <rev-range>)',
  );
  exit(2);
}

bool _hasCommit(String rev) =>
    Process.runSync('git', [
      'cat-file',
      '-e',
      '$rev^{commit}',
    ], workingDirectory: _repo).exitCode ==
    0;

Future<int> _checkFile(String path) async {
  final base = Platform.environment['BUILD_WORKING_DIRECTORY'] ?? _repo;
  final file = File(path).isAbsolute ? File(path) : File('$base/$path');
  final message = await _git([
    'stripspace',
    '--strip-comments',
  ], stdin: file.readAsStringSync());
  final problems = problemsIn(message);
  problems.forEach(stderr.writeln);
  return problems.isEmpty ? 0 : 1;
}

Future<int> _checkRange(String range) async {
  var status = 0;
  final shas = (await _git(['rev-list', '--no-merges', range]))
      .split('\n')
      .where((s) => s.isNotEmpty);
  for (final sha in shas) {
    final message = await _git(['log', '-1', '--format=%B', sha]);
    final problems = problemsIn(message);
    if (problems.isEmpty) continue;
    status = 1;
    stdout.writeln('${sha.substring(0, 12)} ${message.split('\n').first}');
    for (final p in problems) {
      stdout.writeln('  $p');
    }
  }
  return status;
}

/// Runs git in the repo; [stdin] is piped in for the subcommands that read the
/// message from standard input (`stripspace`).
Future<String> _git(List<String> args, {String? stdin}) async {
  final process = await Process.start('git', args, workingDirectory: _repo);
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  if (await process.exitCode != 0) {
    stderr.write(await err);
    exit(2);
  }
  return out;
}
