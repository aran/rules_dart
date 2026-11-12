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

  /// The buildozer commands (`buildozer -f`) that remove them.
  List<String> get commands => [
    for (final MapEntry(key: entry, value: deps) in remove.entries)
      'remove deps ${deps.join(' ')}|$entry',
  ];
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

/// [removals] as buildozer makes them, one dep at a time: [edit] runs
/// `buildozer 'remove deps <dep>' <entry>` on a copy of the BUILD files and
/// answers its exit code. 0: it removed the dep. 3: it changed nothing, as
/// the dep is in a variable or a comprehension, not in a list written in the
/// call. 2: it found no call of that name, as a comprehension or a loop makes
/// the target. Those two are kept, at the place [rules] (the packages' rules)
/// give the entry. Any other code is an error.
Future<Removals> editEach(
  Removals removals,
  List<QueriedRule> rules,
  Future<int> Function(String entry, String dep) edit,
) async {
  final locations = {for (final r in rules) r.entry: r.entryLocation};
  final remove = <String, List<String>>{};
  final kept = [...removals.kept];
  for (final MapEntry(key: entry, value: deps) in removals.remove.entries) {
    for (final dep in deps) {
      final code = await edit(entry, dep);
      final String reason;
      switch (code) {
        case 0:
          remove.putIfAbsent(entry, () => []).add(dep);
          continue;
        case 3:
          reason =
              'buildozer edits only lists written in the call; this one is '
              'in a variable or a comprehension, so remove it there';
        case 2:
          reason =
              'buildozer finds no call named '
              '${entry.substring(entry.lastIndexOf(':') + 1)}, as a '
              'comprehension or a loop makes it, so remove it there';
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
