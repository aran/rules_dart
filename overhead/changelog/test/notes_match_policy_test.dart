/// The release notes and the commit policy read a message the same way: the
/// entries `entriesIn` finds are the ones `cliff.toml` renders, no more, no
/// fewer, and nothing around them.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../commit_policy.dart';

const messages = [
  'feat: plain\n\nChangelog: Entry plain\n',
  'fix: prose after\n\nWhy.\n\nChangelog: `a` entry prose\n\nAssisted by an agent.\n',
  'fix: skip, prose after\n\nChangelog: skip\n\nAssisted by an agent.\n',
  'feat: trailers after\n\nChangelog: Entry trailers\n\nAgent: some/agent\n',
  'feat: two paragraphs after\n\nChangelog: Entry two\n\nGenerated with a tool\n\n'
      'Co-Authored-By: A <a@example.com>\n',
  'feat: beside a trailer\n\nRefs: #1\nChangelog: Entry beside\n'
      'Co-Authored-By: A <a@example.com>\n',
  'feat: in the body\n\nChangelog: Entry body\n\nMore on why.\n\nChangelog: Entry end\n',
  'chore: invisible\n\nWhy.\n',
];

void main(List<String> args) {
  test('the notes hold exactly the entries the policy sees', () {
    final dir = Directory.systemTemp.createTempSync('notes_policy_');
    addTearDown(() => dir.deleteSync(recursive: true));
    String git(List<String> a, {String? input}) {
      final env = {
        for (final who in ['AUTHOR', 'COMMITTER']) ...{
          'GIT_${who}_NAME': 'Test',
          'GIT_${who}_EMAIL': 'test@example.com',
        },
      };
      final file = File('${dir.path}/.input');
      if (input != null) file.writeAsStringSync(input);
      final r = Process.runSync(
        'git',
        [...a, if (input != null) file.path],
        workingDirectory: dir.path,
        environment: env,
      );
      if (r.exitCode != 0) fail('git $a: ${r.stderr}');
      return (r.stdout as String).trim();
    }

    git(['init', '-q']);
    final tree = git(['mktree'], input: null);
    var parent = <String>[];
    for (final m in messages) {
      final sha = git(['commit-tree', tree, ...parent, '-F'], input: m);
      parent = ['-p', sha];
    }
    git(['update-ref', 'HEAD', parent.last]);

    final runfiles = Runfiles.create();
    final notes = Process.runSync(runfiles.rlocation(args[0]), [
      '--workdir',
      dir.path,
      '--repository',
      dir.path,
      '--config',
      runfiles.rlocation(args[1]),
      '--unreleased',
      '--strip',
      'header',
    ]);
    expect(notes.exitCode, 0, reason: notes.stderr as String);

    final body = (notes.stdout as String)
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    final expected = [
      for (final m in messages)
        for (final e in entriesIn(m))
          if (e != 'skip') '- $e',
    ];
    expect(body..sort(), expected..sort());
  });
}
