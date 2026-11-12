// What `bazel run @rules_dart//dart/unused_deps` removes: the written labels
// of a BUILD file entry that stand only for deps the check found unused.
import 'dart:convert';

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
      }),
    );
    expect(report.label, '@@//app:lib');
    expect(report.unused, {'@@//b:b'});
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
    expect(removals.commands, [
      'remove deps //app:util @rules_dart//dart/runfiles:runfiles|//app:lib',
    ]);
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
    expect(removals.commands, ['remove deps //app:util|//app:t']);
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
        (entry, dep) async => codes[dep]!,
      );
      expect(made.commands, ['remove deps //app:gone|//app:t']);
      expect(made.kept.map((k) => k.toString()), [
        'app/BUILD.bazel:9:1: //app:t: kept //app:shared: buildozer edits only '
            'lists written in the call; this one is in a variable or a '
            'comprehension, so remove it there',
        '/ws/app/BUILD.bazel:1:1: //app:generated: kept //app:util: buildozer '
            'finds no call named generated, as a comprehension or a loop makes '
            'it, so remove it there',
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
        (entry, dep) async => 1,
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
}
