// What `bazel run @rules_dart//dart/unused_deps` removes: the written labels
// of a BUILD file entry that stand only for deps the check found unused.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';

import 'unused_deps_fix.dart';

const _mapping = {
  '': '',
  'deps': 'rules_flutter++pub+deps',
  'rules_dart': 'rules_dart+',
  'hub_a': 'hub_a+',
  'hub_b': 'hub_b+',
};

String _canonical(String label) => canonicalLabel(label, _mapping);

QueriedRule _rule(
  String label,
  List<String> deps, {
  String generator = '',
  String kind = 'dart_library',
}) => QueriedRule(
  label: label,
  kind: kind,
  location: '/ws/${label.substring(2, label.indexOf(':'))}/BUILD.bazel:1:1',
  generatorName: generator,
  generatorLocation: generator.isEmpty ? '' : 'app/BUILD.bazel:9:1',
  deps: deps,
);

Removals _find(
  List<UnusedReport> reports,
  List<QueriedRule> rules, {
  Map<String, List<String>> aliases = const {},
}) => findRemovals(
  reports: reports,
  rules: rules,
  aliases: aliases,
  canonical: _canonical,
);

const rightStyle =
    'Write each target as its own call with its deps listed in it, as '
    'Gazelle and buildozer do. A BUILD file that builds deps another way on '
    'purpose can turn the check off for its targets: '
    'package(features = ["-dart_unused_deps"]), or that feature on a target.';

void main() {
  group('canonicalLabel', () {
    test('a main repository label', () {
      expect(_canonical('//app:lib'), '@@//app:lib');
    });
    test('an apparent name, through the mapping', () {
      expect(
        _canonical('@rules_dart//dart/runfiles:runfiles'),
        '@@rules_dart+//dart/runfiles:runfiles',
      );
      expect(_canonical('@deps'), '@@rules_flutter++pub+deps//:deps');
    });
    test('a canonical label stays', () {
      expect(_canonical('@@x+//:y'), '@@x+//:y');
    });
    test('a name the main repository does not map is an error', () {
      expect(() => _canonical('@nope//:y'), throwsFormatException);
    });
  });

  test('aliases resolve to the targets at the end of each chain', () {
    final aliases = {
      '@@//a:one': ['@@//a:two'],
      '@@//a:two': ['@@//a:leaf'],
      '@@//a:either': ['@@//a:leaf', '@@//a:other'],
    };
    expect(resolveAliases('@@//a:one', aliases), {'@@//a:leaf'});
    expect(resolveAliases('@@//a:either', aliases), {
      '@@//a:leaf',
      '@@//a:other',
    });
    expect(resolveAliases('@@//a:leaf', aliases), {'@@//a:leaf'});
  });

  test('a report is read from its JSON', () {
    final report = UnusedReport.parse(
      jsonEncode({
        'label': '@@//app:lib',
        'dependent': '//app:lib',
        'unused': ['@@//b:b'],
        'unreached': ['app/bin/stray.dart'],
        'unreachedOnly': ['@@//c:c'],
        'refused': [
          {'path': 'app/lib/a.dart', 'uri': 'file:///x.dart'},
        ],
      }),
    );
    expect(report.label, '@@//app:lib');
    expect(report.unused, {'@@//b:b'});
    expect(report.unreached, ['app/bin/stray.dart']);
    expect(report.unreachedOnly, {'@@//c:c'});
    expect(report.refused, [(path: 'app/lib/a.dart', uri: 'file:///x.dart')]);
  });

  test('a target with a refused import keeps every dep, and names the '
      'import', () {
    final removals = _find(
      [
        UnusedReport(
          '@@//app:t.program',
          '//app:t',
          {'@@//app:gone'},
          refused: [(path: 'app/bin/main.dart', uri: 'file:///x/gone.dart')],
        ),
        // Its sibling has no refusal of its own to say so, yet shares the
        // entry's srcs.
        UnusedReport('@@//app:t', '//app:t', {'@@//app:gone'}),
      ],
      [
        _rule('//app:t', ['//app:gone', '//app:used'], generator: 't'),
        _rule('//app:t.program', ['//app:gone', '//app:used'], generator: 't'),
      ],
    );
    expect(removals.remove, isEmpty);
    expect(removals.refused.map((r) => r.toString()), [
      "app/BUILD.bazel:9:1: //app:t: app/bin/main.dart names "
          "'file:///x/gone.dart', which the import check refuses (the build "
          'says why). Fix it, then run the fixer again: until then it cannot '
          'tell which deps the target uses',
    ]);
    expect(removals.kept.map((k) => k.toString()), [
      'app/BUILD.bazel:9:1: //app:t: kept //app:gone: no file imports it, but '
          'the target has refused imports, so what it uses is not known; fix '
          'them and run the fixer again',
    ]);
  });

  test('a src main never reaches is named, and a dep only such srcs import '
      'is kept', () {
    final removals = _find(
      [
        for (final label in ['@@//app:t', '@@//app:t.program'])
          UnusedReport(
            label,
            '//app:t',
            {'@@//app:gone'},
            unreached: ['app/bin/stray.dart'],
            unreachedOnly: {'@@//app:x'},
          ),
      ],
      [
        _rule('//app:t', [
          '//app:gone',
          '//app:x',
          '//app:used',
        ], generator: 't'),
        _rule('//app:t.program', [
          '//app:gone',
          '//app:x',
          '//app:used',
        ], generator: 't'),
      ],
    );
    expect(removals.remove, {
      '//app:t': ['//app:gone'],
    });
    expect(removals.unreached.map((u) => u.toString()), [
      'app/BUILD.bazel:9:1: //app:t: main never loads app/bin/stray.dart, one '
          'of its srcs. Remove it from srcs, or import it from a file main '
          'loads: the fixer cannot tell which is meant, and the build fails '
          'until one is done',
    ]);
    expect(removals.kept.map((k) => k.toString()), [
      'app/BUILD.bazel:9:1: //app:t: kept //app:x: only srcs main never loads '
          'import it (app/bin/stray.dart); it goes once they leave srcs',
    ]);
  });

  test('a report of nothing but an unreached src is acted on', () {
    final removals = _find(
      [
        UnusedReport(
          '@@//app:t',
          '//app:t',
          {},
          unreached: ['app/bin/stray.dart'],
        ),
      ],
      [
        _rule('//app:t', ['//app:used']),
      ],
    );
    expect(removals.remove, isEmpty);
    expect(removals.unreached.map((u) => u.path), ['app/bin/stray.dart']);
    expect(removals.kept, isEmpty);
  });

  test('the written labels of the unused deps are removed, as written', () {
    final removals = _find(
      [
        UnusedReport('@@//app:lib', '//app:lib', {
          '@@//app:util',
          '@@rules_dart+//dart/runfiles:runfiles',
        }),
      ],
      [
        _rule('//app:lib', [
          '//app:util',
          '//app:used',
          '@rules_dart//dart/runfiles:runfiles',
        ]),
      ],
    );
    expect(removals.remove, {
      '//app:lib': ['//app:util', '@rules_dart//dart/runfiles:runfiles'],
    });
    expect(removals.kept, isEmpty);
  });

  test('two aliases of one unused target are both removed', () {
    final removals = _find(
      [
        UnusedReport('@@//app:lib', '//app:lib', {'@@hub_spoke+//:path'}),
      ],
      [
        _rule('//app:lib', ['@hub_a//:path', '@hub_b//:path']),
      ],
      aliases: {
        '@@hub_a+//:path': ['@@hub_spoke+//:path'],
        '@@hub_b+//:path': ['@@hub_spoke+//:path'],
      },
    ).remove;
    expect(removals, {
      '//app:lib': ['@hub_a//:path', '@hub_b//:path'],
    });
  });

  test("a macro's target is fixed at the call, once for all its targets", () {
    final removals = _find(
      [
        UnusedReport('@@//app:t.program', '//app:t', {'@@//app:util'}),
        UnusedReport('@@//app:t_on_linux.program', '//app:t', {'@@//app:util'}),
      ],
      [
        _rule('//app:t.program', ['//app:util'], generator: 't'),
        _rule('//app:t_on_linux.program', ['//app:util'], generator: 't'),
        // The test that runs the program takes no deps.
        _rule('//app:t', [], generator: 't', kind: 'flutter_program_test'),
      ],
    );
    expect(removals.remove, {
      '//app:t': ['//app:util'],
    });
  });

  test("a dep another target of the call imports is kept", () {
    final removals = _find(
      [
        UnusedReport('@@//app:t.program', '//app:t', {'@@//app:util'}),
        UnusedReport('@@//app:t_on_linux.program', '//app:t', {}),
      ],
      [
        _rule('//app:t.program', ['//app:util'], generator: 't'),
        _rule('//app:t_on_linux.program', ['//app:util'], generator: 't'),
      ],
    );
    expect(removals.remove, isEmpty);
    expect(removals.kept.single.toString(), contains('imports it'));
  });

  test('a dep a target of the call the check does not judge takes is kept', () {
    final removals = _find(
      [
        UnusedReport('@@//app:t.program', '//app:t', {'@@//app:util'}),
      ],
      [
        _rule('//app:t.program', ['//app:util'], generator: 't'),
        _rule('//app:t_gen', ['//app:util'], generator: 't', kind: 'genrule'),
      ],
    );
    expect(removals.remove, isEmpty);
    expect(
      removals.kept.single.toString(),
      'app/BUILD.bazel:9:1: //app:t: kept //app:util: //app:t_gen (genrule) '
      'takes it too, and the run has no report of it: the check does not '
      'judge it, or the build skipped it',
    );
  });

  test(
    "buildozer's exit codes say what it removes and what it keeps",
    () async {
      final removals = Removals({
        '//app:t': ['//app:gone', '//app:shared'],
        '//app:generated': ['//app:util'],
      }, []);
      final rules = [
        _rule('//app:t.program', [
          '//app:gone',
          '//app:shared',
        ], generator: 't'),
        _rule('//app:generated', ['//app:util']),
      ];
      final codes = {'//app:gone': 0, '//app:shared': 3, '//app:util': 2};
      final made = await editEach(
        removals,
        rules,
        (entry, dep) async => (
          code: codes[dep]!,
          output: codes[dep] == 2
              ? '/tmp/m/app/BUILD.bazel: error while executing commands '
                    '[{[remove deps //app:util]}] on target //app:generated: '
                    "rule 'generated' not found\n"
              : '',
        ),
      );
      expect(made.remove, {
        '//app:t': ['//app:gone'],
      });
      expect(made.kept.map((k) => k.toString()), [
        'app/BUILD.bazel:9:1: //app:t: kept //app:shared: it is written in a '
            'list variable or a comprehension, and the fixer edits only a list '
            "written in the target's own call. $rightStyle",
        '/ws/app/BUILD.bazel:1:1: //app:generated: kept //app:util: '
            "buildozer failed to edit it (rule 'generated' not found). It "
            'fails when it finds no call named generated: a loop or a '
            'comprehension may make the target, or a variable name it. '
            '$rightStyle',
      ]);
    },
  );

  test('any other buildozer exit code is an error', () {
    expect(
      editEach(
        Removals({
          '//app:t': ['//app:util'],
        }, []),
        [
          _rule('//app:t', ['//app:util']),
        ],
        (entry, dep) async => (code: 1, output: ''),
      ),
      throwsFormatException,
    );
  });

  test('a removed dep Bazel still finds is reported', () {
    final left = stillListed(
      Removals({
        '//app:t': ['//app:util', '//app:gone'],
      }, []),
      [
        _rule('//app:t.program', ['//app:util'], generator: 't'),
      ],
    );
    expect(left.map((k) => '${k.location} ${k.dep}'), [
      'app/BUILD.bazel:9:1 //app:util',
    ]);
  });

  test('query output is read, select() branches included', () {
    final line = jsonEncode({
      'type': 'RULE',
      'rule': {
        'name': '//app:t.program',
        'ruleClass': 'flutter_test_program',
        'location': '/ws/app/BUILD.bazel:3:4',
        'attribute': [
          {
            'name': 'deps',
            'stringListValue': ['//a:a'],
            'selectorList': {
              'elements': [
                {
                  'entries': [
                    {
                      'label': '//conditions:default',
                      'stringListValue': ['//b:b'],
                    },
                  ],
                },
              ],
            },
          },
          {'name': 'generator_name', 'stringValue': 't'},
          {'name': 'generator_location', 'stringValue': 'app/BUILD.bazel:3:4'},
        ],
      },
    });
    final rule = QueriedRule.parseAll('$line\n').single;
    expect(rule.deps, ['//a:a', '//b:b']);
    expect(rule.entry, '//app:t');
    expect(rule.entryLocation, 'app/BUILD.bazel:3:4');
  });

  test('a diff shows each change with its context', () {
    expect(
      unifiedDiff(
        'app/BUILD.bazel',
        'a\nb\nc\nd\ne\nf\ng\n',
        'a\nb\nc\ne\nf\ng\n',
      ),
      '--- a/app/BUILD.bazel\n'
      '+++ b/app/BUILD.bazel\n'
      '@@ -2,5 +2,4 @@\n'
      ' b\n'
      ' c\n'
      '-d\n'
      ' e\n'
      ' f\n',
    );
  });

  group('unifiedDiff', () {
    String diff(String before, String after) => unifiedDiff('f', before, after);
    const header = '--- a/f\n+++ b/f\n';

    test('identical files have no hunks', () {
      expect(diff('a\nb\nc\n', 'a\nb\nc\n'), header);
      expect(diff('', ''), header);
    });

    test('inserting every line', () {
      expect(diff('', 'a\nb\n'), '$header@@ -0,0 +1,2 @@\n+a\n+b\n');
    });

    test('deleting every line', () {
      expect(diff('a\nb\n', ''), '$header@@ -1,2 +0,0 @@\n-a\n-b\n');
    });

    test('an edit at the start', () {
      expect(
        diff('a\nb\nc\nd\n', 'x\nb\nc\nd\n'),
        '$header@@ -1,3 +1,3 @@\n-a\n+x\n b\n c\n',
      );
    });

    test('an edit at the end', () {
      expect(
        diff('a\nb\nc\nd\n', 'a\nb\nc\nx\n'),
        '$header@@ -2,3 +2,3 @@\n b\n c\n-d\n+x\n',
      );
    });

    test('an edit in the middle', () {
      expect(
        diff('a\nb\nc\nd\ne\nf\ng\n', 'a\nb\nc\nX\ne\nf\ng\n'),
        '$header@@ -2,5 +2,5 @@\n b\n c\n-d\n+X\n e\n f\n',
      );
    });

    test('a last line without a newline is marked', () {
      const marker = r'\ No newline at end of file';
      expect(
        diff('a\nb', 'a\nb\n'),
        '$header@@ -1,2 +1,2 @@\n a\n-b\n$marker\n+b\n',
      );
      expect(
        diff('a\nb\n', 'a\nc'),
        '$header@@ -1,2 +1,2 @@\n a\n-b\n+c\n$marker\n',
      );
      expect(
        diff('a\nb', 'x\nb'),
        '$header@@ -1,2 +1,2 @@\n-a\n+x\n b\n$marker\n',
      );
      expect(diff('', 'a'), '$header@@ -0,0 +1,1 @@\n+a\n$marker\n');
    });

    test('far apart edits make separate hunks', () {
      final lines = [for (var i = 0; i < 20; i++) 'l$i'];
      final edited = [...lines]
        ..[2] = 'A'
        ..[17] = 'B';
      final out = diff('${lines.join('\n')}\n', '${edited.join('\n')}\n');
      expect(RegExp('^@@', multiLine: true).allMatches(out), hasLength(2));
    });

    test('applying the hunks to the old file gives the new one, minimally', () {
      final random = Random(7);
      for (var round = 0; round < 4000; round++) {
        // Some files end without a newline, and some are empty.
        String file() {
          final lines = [
            for (var i = random.nextInt(14); i > 0; i--)
              'l${random.nextInt(5)}',
          ];
          final text = lines.join('\n');
          return text.isEmpty || random.nextInt(4) == 0 ? text : '$text\n';
        }

        final a = file(), b = file();
        final out = diff(a, b);
        final reason = '${jsonEncode(a)} -> ${jsonEncode(b)}\n$out';
        expect(_applyHunks(a, out), b, reason: reason);
        // Every line of content starts with 'l', so only edits start with
        // '-' or '+' after the two header lines.
        final edits = out
            .split('\n')
            .skip(2)
            .where((l) => l.startsWith('-') || l.startsWith('+'))
            .length;
        final oldLines = _lines(a), newLines = _lines(b);
        expect(
          edits,
          oldLines.length + newLines.length - 2 * _lcs(oldLines, newLines),
          reason: reason,
        );
      }
    });

    test('a very large file with a few edits is quick', () {
      final lines = [for (var i = 0; i < 50000; i++) 'line $i'];
      final edited = [...lines]
        ..removeAt(40000)
        ..[10] = 'changed'
        ..insert(25000, 'added');
      final watch = Stopwatch()..start();
      final out = diff('${lines.join('\n')}\n', '${edited.join('\n')}\n');
      watch.stop();
      // ignore: avoid_print
      print('50,000 lines, 3 edits: ${watch.elapsedMilliseconds} ms');
      expect(RegExp('^@@', multiLine: true).allMatches(out), hasLength(3));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}

/// The length of the longest common subsequence of [a] and [b].
int _lcs(List<String> a, List<String> b) {
  final table = List.generate(
    a.length + 1,
    (_) => List.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      table[i][j] = a[i] == b[j]
          ? table[i + 1][j + 1] + 1
          : max(table[i + 1][j], table[i][j + 1]);
    }
  }
  return table[0][0];
}

/// The lines of [text], each with its `\n`.
List<String> _lines(String text) => [
  for (final m in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text)) m[0]!,
];

/// [old] with the hunks of the unified diff [out] applied, as `patch` does
/// it, strictly: each hunk's starts and counts must agree with its lines and
/// with where it falls in the old and new files (a side with no lines starts
/// at the line it follows), the hunks must come in order without overlapping,
/// and every context and removed line must match [old], newline included.
String _applyHunks(String old, String out) {
  const marker = r'\ No newline at end of file';
  final oldLines = _lines(old);
  expect(out, endsWith('\n'));
  final lines = out.substring(0, out.length - 1).split('\n');
  expect(lines[0], startsWith('--- a/'));
  expect(lines[1], startsWith('+++ b/'));
  final result = <String>[];
  var at = 0;
  var k = 2;
  while (k < lines.length) {
    final header = RegExp(r'^@@ -(\d+),(\d+) \+(\d+),(\d+) @@$')
        .firstMatch(lines[k++]);
    expect(header, isNotNull, reason: 'line ${k - 1} is not a hunk header');
    final [oldStart, oldCount, newStart, newCount] = [
      for (var g = 1; g <= 4; g++) int.parse(header![g]!),
    ];
    final first = oldCount == 0 ? oldStart : oldStart - 1;
    expect(first, greaterThanOrEqualTo(at), reason: 'hunks overlap');
    result.addAll(oldLines.sublist(at, first));
    at = first;
    expect(result.length, newCount == 0 ? newStart : newStart - 1);
    var oldSeen = 0, newSeen = 0;
    while (oldSeen < oldCount || newSeen < newCount) {
      expect(k, lessThan(lines.length), reason: 'hunk ends early');
      final line = lines[k++];
      var text = '${line.substring(1)}\n';
      if (k < lines.length && lines[k] == marker) {
        text = line.substring(1);
        k++;
      }
      switch (line[0]) {
        case ' ':
          expect(oldLines[at++], text);
          result.add(text);
          oldSeen++;
          newSeen++;
        case '-':
          expect(oldLines[at++], text);
          oldSeen++;
        case '+':
          result.add(text);
          newSeen++;
        default:
          fail('not a hunk line: $line');
      }
    }
    expect([oldSeen, newSeen], [oldCount, newCount]);
  }
  result.addAll(oldLines.sublist(at));
  return result.join();
}
