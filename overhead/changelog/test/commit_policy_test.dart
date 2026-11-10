/// Properties of the commit policy: what it accepts and what it refuses.
///
/// Each property is checked over every combination of the subjects and
/// trailers below rather than over one example.
library;

import 'package:test/test.dart';

import '../commit_policy.dart';

List<String> problems(String message) => problemsIn(message);

String message(
  String subject, {
  String body = '',
  List<String> trailers = const [],
}) {
  final parts = [
    subject,
    if (body.isNotEmpty) body,
    if (trailers.isNotEmpty) trailers.join('\n'),
  ];
  return '${parts.join('\n\n')}\n';
}

const userVisibleTypes = ['feat', 'fix', 'perf'];
const otherTypes = [
  'build',
  'chore',
  'ci',
  'docs',
  'refactor',
  'revert',
  'style',
  'test',
];
const allTypes = [...userVisibleTypes, ...otherTypes];

/// Every conventional subject: each type, with and without a scope and `!`.
Iterable<({String subject, bool needsEntry})> subjects() sync* {
  for (final type in allTypes) {
    for (final scope in ['', '(ios)']) {
      for (final bang in ['', '!']) {
        yield (
          subject: '$type$scope$bang: change a thing',
          needsEntry: userVisibleTypes.contains(type) || bang == '!',
        );
      }
    }
  }
}

const validEntries = [
  'Added `foo` to `bar`',
  '`flutter_app.foo` is removed; use `bar`',
  'Default Dart SDK is 3.13.4',
];

/// Entries the policy refuses, each with the words its refusal contains.
final invalidEntries = {
  'added a thing': 'capital letter',
  'Added a thing.': 'period',
  'A${'a' * maxEntryLength}': 'over $maxEntryLength',
};

/// What contributors end a message with, below the `Changelog:` line.
const attributions = [
  'Assisted by an agent.',
  'Agent: some/agent',
  'Co-Authored-By: A <a@example.com>',
  'Generated with a tool\n\nCo-Authored-By: A <a@example.com>',
];

void main() {
  group('accepts', () {
    test('a non-user-visible commit with no trailer', () {
      for (final s in subjects().where((s) => !s.needsEntry)) {
        expect(problems(message(s.subject)), isEmpty, reason: s.subject);
      }
    });

    test('every commit with one valid entry, or with skip', () {
      for (final s in subjects()) {
        for (final entry in [...validEntries, 'skip']) {
          final m = message(s.subject, trailers: ['Changelog: $entry']);
          expect(problems(m), isEmpty, reason: m);
        }
      }
    });

    test('several entries beside other trailers, with a body above', () {
      for (final s in subjects()) {
        final m = message(
          s.subject,
          body: 'Why it changed.',
          trailers: [
            'Refs: #12',
            for (final e in validEntries) 'Changelog: $e',
          ],
        );
        expect(problems(m), isEmpty, reason: m);
      }
    });

    test('whatever follows the entry, wherever it sits', () {
      for (final s in subjects()) {
        for (final entry in [validEntries.first, 'skip']) {
          for (final tail in attributions) {
            final m = 'fix: x\n\nWhy.\n\nChangelog: $entry\n\n$tail\n'
                .replaceFirst('fix: x', s.subject);
            expect(problems(m), isEmpty, reason: m);
            expect(entriesIn(m), [entry], reason: m);
          }
        }
      }
    });

    test('other trailers directly beneath an entry', () {
      final m = message(
        'fix: x',
        trailers: ['Changelog: skip', 'Co-Authored-By: A <a@example.com>'],
      );
      expect(problems(m), isEmpty, reason: m);
    });

    test('exempt subjects, whatever follows them', () {
      for (final subject in [
        'fixup! feat: x',
        'squash! fix: y',
        'amend! fix: y',
        'Merge branch main',
        'Revert "feat: x"',
      ]) {
        for (final trailers in [
          <String>[],
          ['changelog: lowercase'],
          ['Changelog: skip', 'Changelog: Both'],
        ]) {
          final m = message(subject, trailers: trailers);
          expect(problems(m), isEmpty, reason: m);
        }
      }
    });
  });

  group('refuses', () {
    test('a subject that is not a conventional commit', () {
      for (final subject in [
        'Add a thing',
        'feature: add a thing',
        'feat:add a thing',
        'feat(): add a thing',
        'feat : add a thing',
      ]) {
        expect(
          problems(message(subject, trailers: ['Changelog: skip'])),
          contains(contains('not a conventional commit')),
          reason: subject,
        );
      }
    });

    test('a user-visible or breaking commit with no trailer', () {
      for (final s in subjects().where((s) => s.needsEntry)) {
        expect(problems(message(s.subject, body: 'Why.')), [
          contains("need a 'Changelog: <entry>' trailer"),
        ], reason: s.subject);
      }
    });

    test('each malformed entry, on every commit, beside valid ones', () {
      for (final s in subjects()) {
        for (final MapEntry(key: entry, value: why) in invalidEntries.entries) {
          final m = message(
            s.subject,
            trailers: ['Changelog: ${validEntries.first}', 'Changelog: $entry'],
          );
          expect(problems(m), [contains(why)], reason: m);
        }
      }
    });

    test('skip beside an entry, in either order', () {
      for (final s in subjects()) {
        for (final trailers in [
          ['Changelog: skip', 'Changelog: ${validEntries.first}'],
          ['Changelog: ${validEntries.first}', 'Changelog: skip'],
        ]) {
          final m = message(s.subject, trailers: trailers);
          expect(problems(m), [contains('cannot stand beside')], reason: m);
        }
      }
    });

    test('a BREAKING CHANGE footer, pointing at !', () {
      for (final s in subjects()) {
        for (final footer in [
          'BREAKING CHANGE: the API changed',
          'BREAKING-CHANGE: the API changed',
        ]) {
          final m = message(
            s.subject,
            trailers: [footer, 'Changelog: ${validEntries.first}'],
          );
          expect(problems(m), [
            allOf(contains('BREAKING CHANGE'), contains("'!'")),
          ], reason: m);
        }
      }
    });

    test('a Changelog key spelt in another case, by its spelling', () {
      for (final s in subjects()) {
        for (final key in ['changelog', 'CHANGELOG', 'ChangeLog']) {
          final m = message(
            s.subject,
            trailers: ['$key: ${validEntries.first}'],
          );
          final found = problems(m);
          expect(found, [contains("spelled 'Changelog:'")], reason: m);
        }
      }
    });

    test('an entry wrapped onto a second line, indented or not', () {
      for (final s in subjects()) {
        for (final tail in ['missing from `font_files`', '  still the entry']) {
          final m = message(
            s.subject,
            trailers: ['Changelog: ${validEntries.first}', tail],
          );
          expect(problems(m), [contains('must be one line')], reason: m);
        }
      }
    });

    test('a misspelt Changelog key anywhere in the message', () {
      for (final s in subjects()) {
        final m = message(
          s.subject,
          body: 'changelog: ${validEntries.first}',
          trailers: ['Changelog: skip'],
        );
        expect(problems(m), [contains("spelled 'Changelog:'")], reason: m);
      }
    });
  });

  group('pushRange', () {
    bool has(String rev) => rev == 'aaaa';

    test('diffs against a before the clone holds', () {
      expect(pushRange('aaaa', 'bbbb', has), 'aaaa..bbbb');
    });

    test('checks only the pushed commit when the branch is new', () {
      expect(pushRange('0' * 40, 'bbbb', has), 'bbbb^!');
    });

    test('checks only the pushed commit after a force push', () {
      expect(pushRange('cccc', 'bbbb', has), 'bbbb^!');
    });
  });
}
