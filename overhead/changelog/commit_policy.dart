/// The commit policy in AGENTS.md, as a function from a commit message to
/// what is wrong with it.
///
/// A message has a conventional-commit subject. `feat`, `fix`, `perf` and
/// breaking (`!`) commits carry a `Changelog:` line, either one per
/// user-visible change or `Changelog: skip`.
///
/// Every line that starts `Changelog:` is an entry, wherever it sits, so what
/// follows it (an attribution paragraph, say) cannot hide it. `cliff.toml`
/// reads the message the same way; a test holds the two together.
library;

const maxEntryLength = 100;

const _types =
    'build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test';

final _conventional = RegExp(
  r'^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)'
  r'(\([^)]+\))?(!)?: \S',
);
final _userVisibleType = RegExp(r'^(feat|fix|perf)[(!:]');
final _exempt = RegExp(r'^(fixup!|squash!|amend!|Merge |Revert ")');
final _entryStart = RegExp(r'^[A-Z`]');
final _changelogKey = RegExp(r'^changelog\s*:', caseSensitive: false);
final _trailerShaped = RegExp(r'^[A-Za-z0-9-]+\s*:');
final _breakingFooter = RegExp(
  r'^BREAKING[ -]CHANGE\s*:',
  caseSensitive: false,
  multiLine: true,
);

/// The entries [message] gives the release notes, in order, `skip` included.
List<String> entriesIn(String message) => [
  for (final line in message.split('\n'))
    if (line.startsWith('Changelog:')) line.substring(10).trim(),
];

/// The policy violations in [message]. Empty when the message is valid.
List<String> problemsIn(String message) {
  final lines = message.split('\n');
  final subject = lines.first;
  if (_exempt.hasMatch(subject)) return const [];

  final problems = <String>[];
  final conventional = _conventional.firstMatch(subject);
  if (conventional == null) {
    problems.add(
      'subject is not a conventional commit: "type(scope): description" '
      'with type one of $_types',
    );
  }
  final breaking = conventional?.group(3) != null;

  if (_breakingFooter.hasMatch(message)) {
    problems.add(
      "a 'BREAKING CHANGE:' footer is not a git trailer; mark a breaking "
      "change with '!' in the subject, as in 'feat(scope)!: ...'",
    );
  }

  for (final line in lines) {
    if (_changelogKey.hasMatch(line) && !line.startsWith('Changelog:')) {
      problems.add("trailer must be spelled 'Changelog:' exactly: $line");
    }
  }
  final entries = entriesIn(message);

  // The notes take one line, so a wrapped entry would lose its tail.
  for (var i = 0; i + 1 < lines.length; i++) {
    final next = lines[i + 1];
    if (lines[i].startsWith('Changelog:') &&
        next.trim().isNotEmpty &&
        !_trailerShaped.hasMatch(next)) {
      problems.add(
        "a 'Changelog:' entry must be one line; this line follows it: $next",
      );
    }
  }

  if (entries.isEmpty &&
      !lines.any(_changelogKey.hasMatch) &&
      (breaking || _userVisibleType.hasMatch(subject))) {
    problems.add(
      "feat/fix/perf/breaking commits need a 'Changelog: <entry>' trailer, "
      "or 'Changelog: skip' if users cannot notice the change",
    );
  }

  if (entries.contains('skip') && entries.length > 1) {
    problems.add(
      "'Changelog: skip' says users cannot notice the change, so it cannot "
      'stand beside entries; keep one or the other',
    );
  }

  for (final entry in entries) {
    if (entry == 'skip') continue;
    if (entry.isEmpty) {
      problems.add("'Changelog:' trailer is empty");
      continue;
    }
    if (entry.length > maxEntryLength) {
      problems.add('Changelog entry over $maxEntryLength chars: $entry');
    }
    if (entry.endsWith('.')) {
      problems.add('Changelog entry ends with a period: $entry');
    }
    if (!_entryStart.hasMatch(entry)) {
      problems.add(
        'Changelog entry must start with a capital letter or `code`: $entry',
      );
    }
  }
  return problems;
}

/// The revisions `git rev-list` should walk for a push from [before] to
/// [after], as GitHub reports them. [hasCommit] says whether the clone holds
/// a commit.
///
/// A push that creates a branch reports an all-zeros [before], and a force
/// push reports a [before] that the new history may no longer contain, so the
/// clone lacks it. Either way there is no base to diff against, and only the
/// pushed commit itself is checked.
String pushRange(String before, String after, bool Function(String) hasCommit) {
  if (RegExp(r'^0+$').hasMatch(before) || !hasCommit(before)) {
    return '$after^!';
  }
  return '$before..$after';
}
