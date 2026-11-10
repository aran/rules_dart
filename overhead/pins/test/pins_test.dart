/// Properties of the pin check: one revision of overhead throughout, or
/// refused.
library;

import 'package:test/test.dart';

import '../pins.dart';

const sha = '0123456789abcdef0123456789abcdef01234567';
const other = 'fedcba9876543210fedcba9876543210fedcba98';

String gitModule(
  String commit, {
  String remote = 'https://github.com/aran/rules_dart.git',
}) =>
    '''
bazel_dep(name = "overhead", version = "0.0.0", dev_dependency = True)
git_override(
    module_name = "overhead",
    commit = "$commit",
    remote = "$remote",
    strip_prefix = "overhead",
)
''';

String workflow(List<String> refs) => [
  'jobs:',
  for (final (i, ref) in refs.indexed) ...[
    '  job$i:',
    '    uses: aran/rules_dart/.github/workflows/commit-messages.yaml@$ref',
  ],
  '  other:',
  '    steps:',
  '      - uses: actions/checkout@v7',
].join('\n');

void main() {
  group('overheadPin', () {
    test('reads git_override, whatever the order of its attributes', () {
      final pin = overheadPin(gitModule(sha));
      expect(pin, isA<GitPin>());
      expect((pin as GitPin).commit, sha);
      expect(pin.gitHubRepo, 'aran/rules_dart');
    });

    test('ignores overrides of other modules', () {
      expect(
        overheadPin(
          'git_override(module_name = "rules_dart", commit = "$sha", '
          'remote = "x")',
        ),
        isNull,
      );
    });

    test('reads local_path_override', () {
      final pin = overheadPin(
        'local_path_override(\n    module_name = "overhead",\n'
        '    path = "overhead",\n)',
      );
      expect((pin as LocalPin).inRepository, isTrue);
    });

    test('names GitHub repositories however the remote is spelt', () {
      for (final remote in [
        'https://github.com/aran/rules_dart.git',
        'https://github.com/aran/rules_dart',
        'git@github.com:aran/rules_dart.git',
      ]) {
        expect(GitPin(remote, sha).gitHubRepo, 'aran/rules_dart');
      }
    });
  });

  test('usesIn finds each remote uses with its line', () {
    final found = usesIn('ci.yaml', workflow([sha, other]));
    expect(
      [for (final u in found) (u.line, u.repo, u.ref)],
      [
        (3, 'aran/rules_dart', sha),
        (5, 'aran/rules_dart', other),
        (8, 'actions/checkout', 'v7'),
      ],
    );
  });

  group('pinProblems', () {
    test('passes when every call names the pinned commit', () {
      for (final n in [0, 1, 3]) {
        expect(
          pinProblems(
            overheadPin(gitModule(sha)),
            usesIn('w.yaml', workflow(List.filled(n, sha))),
          ),
          isEmpty,
        );
      }
    });

    test('refuses each call at another ref, naming it', () {
      final refs = [sha, other, 'main', sha, 'v1'];
      final problems = pinProblems(
        overheadPin(gitModule(sha)),
        usesIn('w.yaml', workflow(refs)),
      );
      expect(problems, hasLength(3));
      expect(problems, everyElement(contains('pins overhead at $sha')));
    });

    test('ignores other repositories\' actions', () {
      expect(
        pinProblems(overheadPin(gitModule(sha)), [
          Uses('w.yaml', 1, 'actions/checkout', 'v7'),
        ]),
        isEmpty,
      );
    });

    test('refuses a commit that is not a full sha', () {
      for (final commit in ['', 'main', sha.substring(0, 12)]) {
        expect(pinProblems(overheadPin(gitModule(commit)), []), hasLength(1));
      }
    });

    test('refuses no pin, and a local path outside the repository', () {
      expect(pinProblems(null, []), hasLength(1));
      for (final path in ['../rules_dart/overhead', '/Users/x/overhead']) {
        expect(pinProblems(LocalPin(path), []), [contains('git_override')]);
      }
    });

    test('accepts the repository\'s own overhead', () {
      expect(pinProblems(LocalPin('overhead'), []), isEmpty);
    });
  });
}
