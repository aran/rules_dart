import 'dart:io';

const _versionTags = 'v[0-9]*.[0-9]*.[0-9]*';

/// The git range the notes of the release [tag] cover in [repo], or null for
/// a first release, which publishes no notes: no version comes before it for
/// them to say what changed since.
///
/// Earlier means a version [tag] descends from. A version on another branch
/// is not one, nor a tag that names no version.
Future<String?> notesRange(String repo, String tag) async {
  final earlier = await git(repo, [
    'tag',
    '--list',
    _versionTags,
    '--merged',
    tag,
    '--no-contains',
    tag,
  ]);
  if (earlier.trim().isEmpty) return null;
  // The nearest, not the newest by date: a patch release cut on a branch lists
  // only that branch's changes.
  final previous = await git(repo, [
    'describe',
    '--tags',
    '--abbrev=0',
    '--match',
    _versionTags,
    '$tag^',
  ]);
  return '${previous.trim()}..$tag';
}

/// Runs git in [repo] and returns what it printed; a failure ends the program.
Future<String> git(String repo, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repo);
  if (result.exitCode != 0) {
    stderr.writeln('prep: git ${args.join(' ')} failed:\n${result.stderr}');
    exit(1);
  }
  return result.stdout as String;
}
