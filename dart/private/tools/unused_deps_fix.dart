// What `bazel run @rules_dart//dart/unused_deps` removes, worked out from the
// check's reports and from `bazel query`.
//
// The check judges a target's `deps` after Bazel resolves them, and Bazel
// resolves an alias to its actual target, so a report names actual targets
// by canonical label. A BUILD file names what it wrote: an alias (a pub
// hub's `@deps//:path_provider`), in the form its repository mapping gives.
// `bazel query` reads the BUILD files without resolving aliases, and prints
// labels as the main repository writes them, so it supplies the written
// labels, each alias's `actual`, and the BUILD file entry that makes each
// target (`generator_name`, for a macro's).
import 'dart:convert';

import 'package:diffutil_dart/diffutil.dart';

/// One target's report: its canonical [label], the BUILD file entry that
/// states its `deps` ([dependent]), and the canonical labels of the [unused]
/// ones.
class UnusedReport {
  UnusedReport(this.label, this.dependent, this.unused);

  factory UnusedReport.parse(String json) {
    final value = jsonDecode(json) as Map<String, dynamic>;
    return UnusedReport(
      value['label'] as String,
      value['dependent'] as String,
      (value['unused'] as List).cast<String>().toSet(),
    );
  }

  final String label;
  final String dependent;
  final Set<String> unused;
}

/// A rule as `bazel query --output=streamed_jsonproto` gives it, its labels
/// as the main repository writes them.
class QueriedRule {
  QueriedRule({
    required this.label,
    required this.kind,
    required this.location,
    this.generatorName = '',
    this.generatorLocation = '',
    this.deps = const [],
    this.actual = const [],
  });

  final String label;
  final String kind;

  /// Where the rule is declared, `<path>:<line>:<column>`.
  final String location;

  /// The name of the BUILD file's call that made it, when a macro did.
  final String generatorName;

  /// That call's place, `<workspace path>:<line>:<column>`.
  final String generatorLocation;

  /// Its `deps`, every branch of a `select()` included.
  final List<String> deps;

  /// An alias's `actual`, every branch included.
  final List<String> actual;

  /// The BUILD file entry that states its attributes.
  String get entry {
    if (generatorName.isEmpty) return label;
    return '${label.substring(0, label.lastIndexOf(':'))}:$generatorName';
  }

  /// Where [entry] is declared.
  String get entryLocation =>
      generatorLocation.isEmpty ? location : generatorLocation;

  /// The rules of `bazel query --output=streamed_jsonproto` [output].
  static List<QueriedRule> parseAll(String output) => [
    for (final line in const LineSplitter().convert(output))
      if (line.isNotEmpty)
        if ((jsonDecode(line) as Map<String, dynamic>)['rule']
            case final Map<String, dynamic> rule)
          QueriedRule._fromJson(rule),
  ];

  factory QueriedRule._fromJson(Map<String, dynamic> rule) {
    final attributes = {
      for (final a in (rule['attribute'] as List? ?? const []))
        (a as Map<String, dynamic>)['name'] as String: a,
    };
    String string(String name) =>
        attributes[name]?['stringValue'] as String? ?? '';
    List<String> labels(String name) {
      final a = attributes[name];
      if (a == null) return const [];
      return [
        ...(a['stringListValue'] as List? ?? const []).cast<String>(),
        if (a['stringValue'] case final String value when value.isNotEmpty)
          value,
        // A `select()`: each branch's value.
        for (final element
            in (a['selectorList']?['elements'] as List? ?? const []))
          for (final entry in (element['entries'] as List? ?? const [])) ...[
            ...(entry['stringListValue'] as List? ?? const []).cast<String>(),
            if (entry['stringValue'] case final String value
                when value.isNotEmpty)
              value,
          ],
      ];
    }

    return QueriedRule(
      label: rule['name'] as String,
      kind: rule['ruleClass'] as String,
      location: rule['location'] as String? ?? '',
      generatorName: string('generator_name'),
      generatorLocation: string('generator_location'),
      deps: labels('deps'),
      actual: labels('actual'),
    );
  }
}

/// [label], as `bazel query` prints it, in canonical form, through
/// [mapping], the main repository's (`bazel mod dump_repo_mapping ""`).
String canonicalLabel(String label, Map<String, String> mapping) {
  if (label.startsWith('@@')) return label;
  if (label.startsWith('//')) return '@@$label';
  if (!label.startsWith('@')) {
    throw FormatException('not an absolute label: $label');
  }
  final slashes = label.indexOf('//');
  final apparent = label.substring(1, slashes < 0 ? label.length : slashes);
  final canonical = mapping[apparent];
  if (canonical == null) {
    throw FormatException(
      '$label names @$apparent, which the main repository does not map',
    );
  }
  if (slashes < 0) return '@@$canonical//:$apparent';
  return '@@$canonical${label.substring(slashes)}';
}

/// The actual targets [label] (canonical) stands for: itself, or through
/// each alias of [aliases] (canonical label to canonical `actual`s), the
/// targets at the end of the chain.
Set<String> resolveAliases(String label, Map<String, List<String>> aliases) {
  final actual = <String>{};
  final seen = <String>{};
  final pending = [label];
  while (pending.isNotEmpty) {
    final next = pending.removeLast();
    if (!seen.add(next)) continue;
    if (aliases[next] case final targets?) {
      pending.addAll(targets);
    } else {
      actual.add(next);
    }
  }
  return actual;
}

/// A written dep the fixer leaves, and why.
class Kept {
  Kept(this.entry, this.location, this.dep, this.reason);

  final String entry;
  final String location;
  final String dep;
  final String reason;

  @override
  String toString() => '$location: $entry: kept $dep: $reason';
}

/// What to remove: for each BUILD file entry, the deps as it writes them,
/// and what is left alone.
class Removals {
  Removals(this.remove, this.kept);

  /// Entry label to the deps to remove from it, as `bazel query` prints them.
  final Map<String, List<String>> remove;
  final List<Kept> kept;
}

/// The written deps to remove, by the BUILD file entry that states them.
///
/// [reports] are the check's, [rules] every rule of the reported targets'
/// packages, and [canonical] maps a written label to its canonical form. A
/// written dep is removed when every target it resolves to ([aliases]) is
/// unused. Every target its entry makes that lists it must say so: an
/// entry's `deps` reach each target it makes (a test's `.program`, its copy
/// for another platform), and a target that is not checked, or that uses the
/// dep, keeps it.
Removals findRemovals({
  required List<UnusedReport> reports,
  required List<QueriedRule> rules,
  required Map<String, List<String>> aliases,
  required String Function(String label) canonical,
}) {
  final byLabel = {for (final r in rules) canonical(r.label): r};
  final reportOf = {for (final r in reports) r.label: r};
  final byEntry = <String, List<QueriedRule>>{};
  for (final r in rules) {
    byEntry.putIfAbsent(r.entry, () => []).add(r);
  }

  bool unusedBy(QueriedRule rule, String written) {
    final report = reportOf[canonical(rule.label)];
    if (report == null) return false;
    return resolveAliases(
      canonical(written),
      aliases,
    ).every(report.unused.contains);
  }

  final remove = <String, List<String>>{};
  final kept = <Kept>[];
  for (final report in reports) {
    if (report.unused.isEmpty) continue;
    final rule = byLabel[report.label];
    if (rule == null) {
      throw FormatException('bazel query did not return ${report.label}');
    }
    final entry = rule.entry;
    if (remove.containsKey(entry)) continue;
    final removed = <String>[];
    for (final written in rule.deps) {
      if (removed.contains(written) || !unusedBy(rule, written)) continue;
      final keeper = [
        for (final other in byEntry[entry] ?? const <QueriedRule>[])
          if (other.deps.contains(written) && !unusedBy(other, written)) other,
      ].firstOrNull;
      if (keeper == null) {
        removed.add(written);
      } else {
        kept.add(
          Kept(
            entry,
            rule.entryLocation,
            written,
            reportOf.containsKey(canonical(keeper.label))
                ? '${keeper.label} imports it'
                : '${keeper.label} (${keeper.kind}) takes it too, and the '
                      'run has no report of it: the check does not judge it, '
                      'or the build skipped it',
          ),
        );
      }
    }
    if (removed.isNotEmpty) remove[entry] = removed;
  }
  return Removals(remove, kept);
}

/// What a dep the fixer cannot reach asks of the user.
const _rightStyle =
    'Write each target as its own call with its deps listed in it, as '
    'Gazelle and buildozer do. A BUILD file that builds deps another way on '
    'purpose can turn the check off for its targets: '
    'package(features = ["-dart_unused_deps"]), or that feature on a target.';

/// [removals] as buildozer makes them, one dep at a time: [edit] runs
/// `buildozer 'remove deps <dep>' <entry>` on a copy of the BUILD files and
/// answers its exit code and what it printed. 0: it removed the dep. 3: it
/// changed nothing, as the dep is in a variable or a comprehension, not in a
/// list written in the call. 2: the command failed, most often as it found
/// no call of that name (a loop or a comprehension makes the target, or a
/// variable names it). Those two are kept, at the place [rules] (the
/// packages' rules) give the entry. Any other code is an error.
Future<Removals> editEach(
  Removals removals,
  List<QueriedRule> rules,
  Future<({int code, String output})> Function(String entry, String dep) edit,
) async {
  final locations = {for (final r in rules) r.entry: r.entryLocation};
  final remove = <String, List<String>>{};
  final kept = [...removals.kept];
  for (final MapEntry(key: entry, value: deps) in removals.remove.entries) {
    for (final dep in deps) {
      final (:code, :output) = await edit(entry, dep);
      final String reason;
      switch (code) {
        case 0:
          remove.putIfAbsent(entry, () => []).add(dep);
          continue;
        case 3:
          reason =
              'it is written in a list variable or a comprehension, and the '
              "fixer edits only a list written in the target's own call. "
              '$_rightStyle';
        case 2:
          // buildozer's error ends with the reason, after the copy's path
          // and the command.
          final line = output.trim().split('\n').first;
          final said = line.substring(line.lastIndexOf(': ') + 1).trim();
          reason =
              'buildozer failed to edit it${said.isEmpty ? '' : ' ($said)'}. '
              'It fails when it finds no call named '
              '${entry.substring(entry.indexOf(':') + 1)}: a loop or a '
              'comprehension may make the target, or a variable name it. '
              '$_rightStyle';
        default:
          throw FormatException(
            "buildozer 'remove deps $dep' $entry exited $code",
          );
      }
      kept.add(Kept(entry, locations[entry] ?? '', dep, reason));
    }
  }
  return Removals(remove, kept);
}

/// The deps of [removals] Bazel still finds once buildozer has removed them,
/// read from [after], the rules of the same packages queried again. There
/// should be none: buildozer removed each from the call.
List<Kept> stillListed(Removals removals, List<QueriedRule> after) {
  final byEntry = <String, List<QueriedRule>>{};
  for (final r in after) {
    byEntry.putIfAbsent(r.entry, () => []).add(r);
  }
  return [
    for (final MapEntry(key: entry, value: deps) in removals.remove.entries)
      for (final dep in deps)
        if ((byEntry[entry] ?? const <QueriedRule>[]).where(
              (r) => r.deps.contains(dep),
            )
            case final rules when rules.isNotEmpty)
          Kept(
            entry,
            rules.first.entryLocation,
            dep,
            'buildozer removed it from the call, but Bazel still finds it, '
            'so remove it by hand',
          ),
  ];
}

/// The lines of [text], each with its `\n`; the last has none when [text]
/// does not end with one.
List<String> _lines(String text) {
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final end = text.indexOf('\n', start);
    if (end < 0) {
      lines.add(text.substring(start));
      break;
    }
    lines.add(text.substring(start, end + 1));
    start = end + 1;
  }
  return lines;
}

/// A unified diff of [before] to [after], both [path], as `git apply` and
/// `patch` take it.
String unifiedDiff(String path, String before, String after) {
  // Each line keeps its newline, so a last line without one differs from
  // the same text with one, and is marked as it is printed.
  final a = _lines(before);
  final b = _lines(after);
  // Myers' diff in linear space, which skips the lines the files share
  // at both ends. Its updates are single lines, last line first; an insert's
  // position is the line of [a] it goes before.
  final removed = List.filled(a.length, false);
  final inserted = List.filled(a.length + 1, 0);
  for (final update in calculateListDiff<String>(
    a,
    b,
    detectMoves: false,
  ).getUpdates(batch: false)) {
    switch (update) {
      case Remove(:final position, :final count):
        removed.fillRange(position, position + count, true);
      case Insert(:final position, :final count):
        inserted[position] += count;
      default:
        throw StateError('Unexpected diff update $update');
    }
  }
  // Each line: ' ', '-' or '+', with its line numbers. Between two unchanged
  // lines the deletions come first, then the insertions.
  final ops = <(String, int, int)>[];
  var i = 0, j = 0;
  for (var p = 0; p <= a.length; p++) {
    final matched = p < a.length && !removed[p];
    if (matched || p == a.length) {
      // The new lines before it: those inserted since the last unchanged line.
      var target = j;
      for (var q = i; q <= p; q++) {
        target += inserted[q];
      }
      while (i < p) {
        ops.add(('-', i++, j));
      }
      while (j < target) {
        ops.add(('+', i, j++));
      }
      if (matched) {
        ops.add((' ', i++, j++));
      }
    }
  }
  const context = 2;
  final out = StringBuffer('--- a/$path\n+++ b/$path\n');
  var k = 0;
  while (k < ops.length) {
    if (ops[k].$1 == ' ') {
      k++;
      continue;
    }
    var from = k - context < 0 ? 0 : k - context;
    var to = k;
    // Extend while the next change is within twice the context.
    while (to < ops.length) {
      if (ops[to].$1 != ' ') {
        to++;
        continue;
      }
      var run = to;
      while (run < ops.length && ops[run].$1 == ' ') {
        run++;
      }
      if (run < ops.length && run - to <= 2 * context) {
        to = run;
      } else {
        to = to + context > ops.length ? ops.length : to + context;
        break;
      }
    }
    final hunk = ops.sublist(from, to);
    final oldCount = hunk.where((o) => o.$1 != '+').length;
    final newCount = hunk.where((o) => o.$1 != '-').length;
    // A side's start is its first line of the hunk; with none, the line the
    // hunk follows, 0 at the start of the file.
    int start(int before, int count) => count == 0 ? before : before + 1;
    out.writeln(
      '@@ -${start(hunk.first.$2, oldCount)},$oldCount '
      '+${start(hunk.first.$3, newCount)},$newCount @@',
    );
    for (final (op, ai, bj) in hunk) {
      final line = op == '+' ? b[bj] : a[ai];
      out.write('$op$line');
      if (!line.endsWith('\n')) out.write('\n\\ No newline at end of file\n');
    }
    k = to;
  }
  return out.toString();
}
