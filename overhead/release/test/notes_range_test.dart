import 'dart:io';

import 'package:test/test.dart';

import '../notes_range.dart';

/// What the notes of a release cover, against real repositories: a first
/// release has none, and a later one has what came since the version it
/// descends from.
void main() {
  late Directory repo;
  late Map<String, String> environment;

  Future<void> run(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: repo.path,
      environment: environment,
    );
    expect(result.exitCode, 0, reason: '$args: ${result.stderr}');
  }

  Future<void> commit(String subject) =>
      run(['commit', '--quiet', '--allow-empty', '-m', subject]);

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('notes_range');
    final noConfig = File('${repo.path}.gitconfig')..writeAsStringSync('');
    addTearDown(() {
      repo.deleteSync(recursive: true);
      noConfig.deleteSync();
    });
    // The fixture's history is thrown away, and owes nothing to the host's git
    // configuration.
    environment = {
      'GIT_CONFIG_GLOBAL': noConfig.path,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_AUTHOR_NAME': 'test',
      'GIT_AUTHOR_EMAIL': 'test@example.invalid',
      'GIT_COMMITTER_NAME': 'test',
      'GIT_COMMITTER_EMAIL': 'test@example.invalid',
    };
    await run(['init', '--quiet', '--initial-branch=main']);
  });

  test('a first release has no notes', () async {
    await commit('feat: one');
    await commit('feat: two');
    await run(['tag', 'v0.1.0']);
    expect(await notesRange(repo.path, 'v0.1.0'), isNull);
  });

  test('a first release on the root commit has no notes', () async {
    await commit('feat: one');
    await run(['tag', 'v0.1.0']);
    expect(await notesRange(repo.path, 'v0.1.0'), isNull);
  });

  test('a tag that is not a version does not make a release later', () async {
    await commit('feat: one');
    await run(['tag', 'pre-squash']);
    await commit('feat: two');
    await run(['tag', 'v0.1.0']);
    expect(await notesRange(repo.path, 'v0.1.0'), isNull);
  });

  test('a version on another branch does not make a release later', () async {
    await commit('feat: one');
    await run(['checkout', '--quiet', '-b', 'other']);
    await commit('feat: other');
    await run(['tag', 'v9.0.0']);
    await run(['checkout', '--quiet', 'main']);
    await commit('feat: two');
    await run(['tag', 'v0.1.0']);
    expect(await notesRange(repo.path, 'v0.1.0'), isNull);
  });

  test('a later release covers what came since the last version', () async {
    await commit('feat: one');
    await run(['tag', 'v0.1.0']);
    await commit('feat: two');
    await run(['tag', 'v0.2.0']);
    expect(await notesRange(repo.path, 'v0.2.0'), 'v0.1.0..v0.2.0');
  });
}
