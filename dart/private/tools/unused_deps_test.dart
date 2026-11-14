// The unused-dependency check: every entry of a target's `deps` is named by
// an import or export of one of its files. Driven through `runCheck`, as the
// Bazel action runs it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'kernel_tool/args.dart';
import 'kernel_tool/check_command.dart';
import 'kernel_tool/directives.dart';
import 'kernel_tool/policy.dart';
import 'kernel_tool/unused_deps.dart';
import 'kernel_tool/uris.dart';

const _packageConfig = {
  'configVersion': 2,
  'packages': [
    {'name': 'app', 'rootUri': '../app', 'packageUri': 'lib/'},
    {'name': 'a', 'rootUri': '../a', 'packageUri': 'lib/'},
    {'name': 'b', 'rootUri': '../b', 'packageUri': 'lib/'},
    // Outside the kernel roots: its files are not looked into.
    {'name': 'c', 'rootUri': 'file:///elsewhere/c/', 'packageUri': 'lib/'},
    {'name': 'split', 'rootUri': '../split', 'packageUri': 'lib/'},
  ],
};

/// A dependency as `_add_unused_deps_args` describes it.
typedef _Dep = ({
  String label,
  List<String> files,
  List<String> packages,
  List<String> reach,
});

_Dep _lib(String label, String package, List<String> files) =>
    (label: label, files: files, packages: [package], reach: [package]);

final _a = _lib('//a', 'a', ['a/lib/a.dart', 'a/lib/src/a_impl.dart']);
final _b = _lib('//b', 'b', ['b/lib/b.dart']);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('unused_deps_'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Checks target `//app:t` of package `app`, holding [srcs] (root-relative
  /// path to text), against [deps]. Returns the diagnostics, empty on a pass.
  Future<String> check(
    Map<String, String> srcs,
    List<_Dep> deps, {
    bool unused = true,
    List<String> extra = const [],
    bool statesPackage = true,
    Map<String, String> uses = const {},
    List<String> entries = const [],
    List<String> srcDirs = const [],
    bool? expectStamp,
  }) async {
    String write(String rel, [String text = '']) {
      final file = File('${dir.path}/root/$rel');
      if (!file.existsSync()) {
        file
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }
      return file.path;
    }

    write('app/pc.json', jsonEncode(_packageConfig));
    final args = [
      '--label',
      '//app:t',
      '--package-config',
      '${dir.path}/root/app/pc.json',
      if (statesPackage) ...['--package-name', 'app', '--package-root', 'app'],
      '--multi-root',
      '${dir.path}/root',
      for (final e in srcs.entries) ...['--src', write(e.key, e.value)],
      for (final d in deps) ...[
        for (final f in d.files) ...['--dep-file', write(f)],
        for (final p in d.reach) ...['--available-package', p],
        '--dep',
        [d.label, 'file', for (final f in d.files) write(f)].join('\t'),
        '--dep',
        [d.label, 'package', ...d.packages].join('\t'),
        '--dep',
        [d.label, 'reach', ...d.reach].join('\t'),
      ],
      for (final e in uses.entries) ...['--use-src', write(e.key, e.value)],
      for (final d in srcDirs) ...['--src', '${dir.path}/root/$d'],
      for (final e in entries) ...['--entry', '${dir.path}/root/$e'],
      if (unused) ...['--check-unused', '--dependent', '//app:t'],
      ...extra,
      '--output',
      '${dir.path}/stamp',
    ];
    final err = StringBuffer();
    final code = await runCheck(Args.parse('check', args), err: err);
    expect(File('${dir.path}/stamp').existsSync(), expectStamp ?? code == 0);
    return code == 0 ? '' : err.toString();
  }

  const lib = 'app/lib/main.dart';

  group('a dependency counts as used when', () {
    final cases = <String, (Map<String, String>, List<_Dep>)>{
      'a file imports it': ({lib: "import 'package:a/a.dart';"}, [_a]),
      'a file exports it': ({lib: "export 'package:a/a.dart';"}, [_a]),
      'it holds a library under src/': (
        {lib: "import 'package:a/src/a_impl.dart';"},
        [_a],
      ),
      'only another file of the target imports it': (
        {
          lib: "import 'src/impl.dart';",
          'app/lib/src/impl.dart': "import 'package:b/b.dart';",
        },
        [_b],
      ),
      'only one branch of a conditional import names it': (
        {
          lib:
              "import 'package:a/a.dart' "
              "if (dart.library.js_interop) 'package:b/b.dart';",
        },
        [_a, _b],
      ),
      'a test imports a support file it holds': (
        {'app/test/t_test.dart': "import '../support/helper.dart';"},
        [
          _lib('//app:support', 'app', ['app/support/helper.dart']),
        ],
      ),
      'a package whose files are not listed is imported': (
        {lib: "import 'package:c/c.dart';"},
        [
          (label: '//c', files: [], packages: ['c'], reach: ['c']),
        ],
      ),
      'it passes on the package imported (a facade)': (
        {lib: "import 'package:c/c.dart';"},
        [
          (label: '//facade', files: [], packages: [], reach: ['c']),
        ],
      ),
    };
    for (final MapEntry(key: name, value: (srcs, deps)) in cases.entries) {
      test(name, () async => expect(await check(srcs, deps), isEmpty));
    }
  });

  test(
    'the deps no file names are reported, a line each, with the fix',
    () async {
      final out = await check(
        {lib: "import 'package:a/a.dart';"},
        [_a, _b, _lib('//c', 'c', [])],
        extra: [
          '--dep',
          '//b\tname\t@b_repo//b',
          '--dep',
          '//c\tname\t:c',
          '--dependent',
          '//app:macro_call',
        ],
      );
      expect(
        out.trim(),
        '//app:macro_call: no file imports or exports these deps:\n'
        '  @b_repo//b\n'
        '  :c\n'
        'bazel run @rules_dart//dart/unused_deps -- //app:all removes them. '
        'One used without an import is exempt when its rule returns '
        'DartUsedWithoutImportInfo; features = ["-dart_unused_deps"] turns the '
        'check off.',
      );
    },
  );

  test('--report writes the unused deps instead of failing', () async {
    final report = '${dir.path}/report.json';
    final out = await check(
      // A strict-deps violation is the validation's to fail, not the report's.
      {lib: "import 'package:a/a.dart'; import 'package:b/b.dart';"},
      [_a, _lib('//c', 'c', [])],
      extra: ['--report', report],
      expectStamp: false,
    );
    expect(out, isEmpty);
    expect(jsonDecode(File(report).readAsStringSync()), {
      'label': '//app:t',
      'dependent': '//app:t',
      'unused': ['//c'],
      'unreached': <String>[],
      'unreachedOnly': <String>[],
      'notLoaded': <String>[],
      'refused': <Object>[],
    });
  });

  test('--report names the srcs main never reaches, and keeps apart the deps '
      'only they import', () async {
    const main = 'app/test/t_test.dart';
    final report = '${dir.path}/report.json';
    final out = await check(
      {main: '', 'app/test/stray.dart': "import 'package:a/a.dart';"},
      [_a, _b],
      entries: [main],
      extra: ['--report', report],
      expectStamp: false,
    );
    expect(out, isEmpty);
    expect(jsonDecode(File(report).readAsStringSync()), {
      'label': '//app:t',
      'dependent': '//app:t',
      'unused': ['//b'],
      'unreached': ['${dir.path}/root/app/test/stray.dart'],
      'unreachedOnly': ['//a'],
      'notLoaded': <String>[],
      'refused': <Object>[],
    });
  });

  test(
    '--report names the refused imports, on every conditional branch',
    () async {
      final report = '${dir.path}/report.json';
      final out = await check(
        {
          lib:
              "import 'package:a/a.dart' if (dart.library.io) "
              "'file:///x/b.dart';",
        },
        [_a, _b],
        extra: ['--report', report],
        expectStamp: false,
      );
      expect(out, isEmpty);
      expect(jsonDecode(File(report).readAsStringSync()), {
        'label': '//app:t',
        'dependent': '//app:t',
        'unused': ['//b'],
        'unreached': <String>[],
        'unreachedOnly': <String>[],
        'notLoaded': <String>[],
        'refused': [
          {'path': '${dir.path}/root/$lib', 'uri': 'file:///x/b.dart'},
        ],
      });
    },
  );

  test('--report names a refused part', () async {
    final report = '${dir.path}/report.json';
    final out = await check(
      {lib: "part 'file:///x/part.dart';"},
      [],
      extra: ['--report', report],
      expectStamp: false,
    );
    expect(out, isEmpty);
    expect(jsonDecode(File(report).readAsStringSync()), {
      'label': '//app:t',
      'dependent': '//app:t',
      'unused': <String>[],
      'unreached': <String>[],
      'unreachedOnly': <String>[],
      'notLoaded': <String>[],
      'refused': [
        {'path': '${dir.path}/root/$lib', 'uri': 'file:///x/part.dart'},
      ],
    });
  });

  test('an executable stating no package uses the facade its own file '
      'resolves through', () async {
    final out = await check(
      {
        'app/bin/main.dart': "import 'package:app/util.dart';",
        'app/lib/util.dart': '',
      },
      [
        (label: '//app:facade', files: [], packages: ['app'], reach: ['app']),
      ],
      statesPackage: false,
    );
    expect(out, isEmpty);
  });

  test("the package's link hook uses what it imports", () async {
    final out = await check(
      {lib: "import 'package:a/a.dart';"},
      [_a, _b],
      uses: {'app/hook/link.dart': "import 'package:b/b.dart';"},
    );
    expect(out, isEmpty);
  });

  test(
    'a file the rule writes uses what it imports and is not judged',
    () async {
      // A test's bootstrap: it imports the test's file and the runner. An
      // import nothing provides would fail a file of the target.
      final out = await check(
        {'app/test/t_test.dart': 'void main() {}'},
        [_a],
        uses: {
          'app/test/t.bootstrap.dart':
              "import 't_test.dart';\n"
              "import 'package:a/a.dart';\n"
              "import 'package:undeclared/x.dart';",
        },
      );
      expect(out, isEmpty);
    },
  );

  test('a part names no dependency', () async {
    final out = await check(
      {
        lib: "part 'main.g.dart';",
        'app/lib/main.g.dart': "part of 'main.dart';",
      },
      [_a],
    );
    expect(out, contains('\n  //a\n'));
  });

  test('a package split over two targets: only the holder is used', () async {
    final out = await check(
      {lib: "import 'package:split/one.dart';"},
      [
        _lib('//split:one', 'split', ['split/lib/one.dart']),
        _lib('//split:two', 'split', ['split/lib/two.dart']),
      ],
    );
    expect(out, contains('\n  //split:two\n'));
    expect(out, isNot(contains('//split:one')));
  });

  test(
    'a facade reaching a package a direct dependency holds is unused',
    () async {
      final out = await check(
        {lib: "import 'package:a/a.dart';"},
        [
          _a,
          (label: '//facade', files: [], packages: [], reach: ['a']),
        ],
      );
      expect(out, contains('\n  //facade\n'));
    },
  );

  test('an exempt dependency is never reported, and an import of a file it '
      'holds names it, not another dependency reaching its package', () async {
    final out = await check(
      {lib: "import 'package:b/b.dart';"},
      [
        _b,
        _lib('//b:other', 'b', ['b/lib/other.dart']),
        (
          label: '//a',
          files: ['a/lib/a.dart'],
          packages: ['a'],
          reach: ['a', 'b'],
        ),
      ],
      extra: ['--dep', '//b\texempt', '--dep', '//b:other\texempt'],
    );
    expect(out, contains('\n  //a\n'));
    expect(out, isNot(contains('//b')));
  });

  group('a package no dependency holds or contributes', () {
    final imported = {lib: "import 'package:c/c.dart';"};
    final reaching = (
      label: '//a',
      files: ['a/lib/a.dart'],
      packages: ['a'],
      reach: ['a', 'c'],
    );
    final facade = (
      label: '//facade',
      files: <String>[],
      packages: <String>[],
      reach: ['c'],
    );

    test('names a facade passing it on, not a library reaching it, '
        'under the layering check', () async {
      final out = await check(
        imported,
        [reaching, facade],
        extra: [
          '--check-layering',
          '--direct-package',
          'a',
          '--direct-package',
          'c',
        ],
      );
      expect(out, contains('\n  //a\n'));
      expect(out, isNot(contains('//facade')));
    });

    test('names each dependency reaching it without the layering check, '
        'which lets a file import it through any of them', () async {
      expect(await check(imported, [reaching]), isEmpty);
    });
  });

  group("an executable's files main never reaches", () {
    const main = 'app/test/t_test.dart';
    final reached = <String, Map<String, String>>{
      'through import, export, part and every conditional branch': {
        main:
            "import 'a.dart' if (dart.library.js_interop) 'b.dart';\n"
            "export 'package:app/c.dart';\n"
            "part 't_test.g.dart';",
        'app/test/a.dart': '',
        'app/test/b.dart': "import 'd.dart';",
        'app/test/d.dart': '',
        'app/lib/c.dart': '',
        'app/test/t_test.g.dart': "part of 't_test.dart';",
      },
    };
    for (final MapEntry(key: name, value: srcs) in reached.entries) {
      test(
        'pass when every file is reached $name',
        () async => expect(await check(srcs, [], entries: [main]), isEmpty),
      );
    }

    test('are reported, a line each, with the fix', () async {
      final out = await check(
        {
          main: "import 'support.dart';",
          'app/test/support.dart': '',
          'app/test/other_support.dart': "import 'package:a/a.dart';",
        },
        [_a],
        entries: [main],
      );
      expect(
        out.trim(),
        '//app:t: main never imports, exports or includes as a part these '
        'srcs, so the program never loads them, while what they import counts '
        'as used:\n'
        '  ${dir.path}/root/app/test/other_support.dart\n'
        'Remove them from srcs; a file read at run time belongs in data. '
        'features = ["-dart_unused_deps"] turns the check off.',
      );
    });

    test("pass when reached from the package's link hook", () async {
      final out = await check(
        {main: '', lib: ''},
        [],
        uses: {'app/hook/link.dart': "import 'package:app/main.dart';"},
        entries: [main],
      );
      expect(out, isEmpty);
    });

    test('pass when reached from a file the rule writes', () async {
      final out = await check(
        {main: '', 'app/test/support.dart': ''},
        [],
        uses: {'app/test/t.bootstrap.dart': "import 'support.dart';"},
        entries: [main],
      );
      expect(out, isEmpty);
    });

    test('pass when a file the rule writes reaches them through the '
        "compile's multi-root scheme", () async {
      final out = await check(
        {main: "import 'package:a/a.dart';"},
        [_a],
        uses: {
          'bin/app/t.bootstrap.dart': "import 'org-dartlang-app:///$main';",
        },
        entries: [main],
      );
      expect(out, isEmpty);
    });

    test('pass when a file the rule writes reaches them by a path climbing '
        'from its output directory', () async {
      final out = await check(
        {main: ''},
        [],
        uses: {'bin/app/t.bootstrap.dart': "import '../../$main';"},
        entries: [main],
        extra: ['--multi-root', '${dir.path}/root/bin'],
      );
      expect(out, isEmpty);
    });

    for (final written in [
      'org-dartlang-app:///app/test/support.dart',
      'support.dart?v=1',
    ]) {
      test("pass when reached only through a source's refused import, which "
          'loads them once fixed: $written', () async {
        final out = await check(
          {main: "import '$written';", 'app/test/support.dart': ''},
          [],
          entries: [main],
        );
        expect(out, contains(written));
        expect(out, isNot(contains('main never imports')));
      });
    }

    // What main reaches is not known while it cannot be followed, so no
    // file is reported beside the refusal, which fails the build itself.
    for (final (name, written) in [
      ('a file: URI', 'file://<root>/app/test/support.dart'),
      ('an absolute path', '<root>/app/test/support.dart'),
      (
        'a scheme without the multi-root shape',
        'org-dartlang-app:app/test/support.dart',
      ),
    ]) {
      test("pass beside a source's refused import that cannot be followed: "
          '$name', () async {
        final uri = written.replaceFirst('<root>', '${dir.path}/root');
        final out = await check(
          {main: "import '$uri';", 'app/test/support.dart': ''},
          [],
          entries: [main],
        );
        expect(out, contains(uri));
        expect(out, isNot(contains('main never imports')));
      });
    }

    test("are reported beside a source's refused import", () async {
      final out = await check(
        {
          main: "import 'support.dart?v=1';",
          'app/test/support.dart': '',
          'app/test/stray.dart': '',
        },
        [],
        entries: [main],
      );
      expect(out, contains('support.dart?v=1'));
      expect(out, contains('main never imports'));
      expect(out, contains('app/test/stray.dart'));
      expect(out, isNot(contains('app/test/support.dart\n')));
    });

    test('are not reached by a path that climbs above the exec root from a '
        'file the rule writes', () {
      // Exec paths are relative in an action, which [check] cannot write.
      final config = PackageConfig.parse(
        jsonEncode(_packageConfig),
        'app/pc.json',
      );
      const bootstrap = CheckedFile(
        path: 'bazel-out/bin/app/t.bootstrap.dart',
        rootPath: 'app/t.bootstrap.dart',
        uri: 'org-dartlang-root:///app/t.bootstrap.dart',
        directives: Directives([], [], false),
      );
      final roots = ['.', 'bazel-out/bin'];
      for (final loaded in [
        unjudgedUri(config, '//app:t', roots, {bootstrap.path}),
        anyLoadedUri(config, '//app:t', roots),
      ]) {
        expect(
          loaded('../../../app/test/support.dart', bootstrap),
          'org-dartlang-root:///app/test/support.dart',
        );
        expect(loaded('../../../../app/test/support.dart', bootstrap), isNull);
      }
    });

    group('of a srcs entry holding several', () {
      const a = 'app/test/support/a.dart';
      const b = 'app/test/support/b.dart';
      String entry(String label, List<String> paths) =>
          [label, for (final p in paths) '${dir.path}/root/$p'].join('\t');
      List<String> entryArgs(List<String> paths) => [
        '--src-entry',
        entry('//app/test/support', paths),
      ];

      test('pass when main reaches another of them, and what they import is '
          'not judged', () async {
        final out = await check(
          {
            main: "import 'support/a.dart';",
            a: '',
            b: "import 'package:b/b.dart';",
          },
          [],
          entries: [main],
          extra: entryArgs([a, b]),
        );
        expect(out, isEmpty);
      });

      test('use no dep', () async {
        final out = await check(
          {
            main: "import 'support/a.dart';",
            a: '',
            b: "import 'package:b/b.dart';",
          },
          [_b],
          entries: [main],
          extra: entryArgs([a, b]),
        );
        expect(out, contains('no file imports or exports these deps'));
        expect(out, contains('//b'));
      });

      test('still use what the reached ones import', () async {
        final out = await check(
          {
            main: "import 'support/b.dart';",
            a: "import 'package:a/a.dart';",
            b: "import 'package:b/b.dart';",
          },
          [_b],
          entries: [main],
          extra: entryArgs([a, b]),
        );
        expect(out, isEmpty);
      });

      test('are reached through a file of the entry', () async {
        final out = await check(
          {main: "import 'support/a.dart';", a: "import 'b.dart';", b: ''},
          [],
          entries: [main],
          extra: entryArgs([a, b]),
        );
        expect(out, isEmpty);
      });

      test('fail naming the entry when none is reached, as it can go', () async {
        final out = await check(
          {main: '', a: '', b: "import 'package:b/b.dart';"},
          [_b],
          entries: [main],
          extra: entryArgs([a, b]),
        );
        expect(
          out,
          contains(
            '  //app/test/support (${dir.path}/root/$a, ${dir.path}/root/$b)\n',
          ),
        );
        // What the entry imports stays apart until it goes: not a use the
        // failure hides behind, nor a dep to take away first.
        expect(out, isNot(contains('no file imports or exports')));
      });

      test('a one-file entry fails naming the entry', () async {
        final out = await check(
          {main: '', a: ''},
          [],
          entries: [main],
          extra: entryArgs([a]),
        );
        expect(out, contains('  //app/test/support (${dir.path}/root/$a)\n'));
      });

      test(
        'are in the report as not loaded, and their deps as unused',
        () async {
          final report = '${dir.path}/report.json';
          final out = await check(
            {
              main: "import 'support/a.dart';",
              a: '',
              b: "import 'package:b/b.dart';",
            },
            [_b],
            entries: [main],
            extra: [
              ...entryArgs([a, b]),
              '--report',
              report,
            ],
            expectStamp: false,
          );
          expect(out, isEmpty);
          expect(jsonDecode(File(report).readAsStringSync()), {
            'label': '//app:t',
            'dependent': '//app:t',
            'unused': ['//b'],
            'unreached': <String>[],
            'unreachedOnly': <String>[],
            'notLoaded': ['${dir.path}/root/$b'],
            'refused': <Object>[],
          });
        },
      );

      test('in the report, an entry none of whose files is reached is named, '
          'its deps kept for the user to judge', () async {
        final report = '${dir.path}/report.json';
        await check(
          {main: '', a: '', b: "import 'package:b/b.dart';"},
          [_b],
          entries: [main],
          extra: [
            ...entryArgs([a, b]),
            '--report',
            report,
          ],
          expectStamp: false,
        );
        final written = jsonDecode(File(report).readAsStringSync()) as Map;
        expect(written['unreached'], [
          '//app/test/support (${dir.path}/root/$a, ${dir.path}/root/$b)',
        ]);
        expect(written['unreachedOnly'], ['//b']);
        expect(written['unused'], isEmpty);
        expect(written['notLoaded'], isEmpty);
      });

      group('with the unused check off', () {
        test('need no dep when main reaches another of them', () async {
          final out = await check(
            {
              main: "import 'support/a.dart';",
              a: '',
              b: "import 'package:b/b.dart';",
            },
            [],
            unused: false,
            entries: [main],
            extra: entryArgs([a, b]),
          );
          expect(out, isEmpty);
        });

        test(
          'need no dep when main reaches none, and the entry may stay',
          () async {
            final out = await check(
              {main: '', a: '', b: "import 'package:b/b.dart';"},
              [],
              unused: false,
              entries: [main],
              extra: entryArgs([a, b]),
            );
            expect(out, isEmpty);
          },
        );

        test('are judged when main reaches them', () async {
          final out = await check(
            {
              main: "import 'support/b.dart';",
              a: '',
              b: "import 'package:b/b.dart';",
            },
            [],
            unused: false,
            entries: [main],
            extra: entryArgs([a, b]),
          );
          expect(out, contains('package:b/b.dart'));
        });

        test('are in the report as not loaded, and nothing else is', () async {
          final report = '${dir.path}/report.json';
          await check(
            {main: '', a: '', b: "import 'package:b/b.dart';"},
            [],
            unused: false,
            entries: [main],
            extra: [
              ...entryArgs([a, b]),
              '--dependent',
              '//app:t',
              '--report',
              report,
            ],
            expectStamp: false,
          );
          expect(jsonDecode(File(report).readAsStringSync()), {
            'label': '//app:t',
            'dependent': '//app:t',
            'unused': <String>[],
            'unreached': <String>[],
            'unreachedOnly': <String>[],
            'notLoaded': ['${dir.path}/root/$a', '${dir.path}/root/$b'],
            'refused': <Object>[],
          });
        });
      });
    });

    test('are not reached by a doc import, which loads nothing', () async {
      final out = await check(
        {
          main: "/// @docImport 'support.dart';\nlibrary;",
          'app/test/support.dart': '',
        },
        [],
        entries: [main],
      );
      expect(out, contains('main never imports'));
      expect(out, contains('app/test/support.dart\n'));
    });

    test('with the unused check off, one listed by itself is still judged, '
        'as no other program can answer for it', () async {
      final out = await check(
        {main: '', 'app/test/support.dart': "import 'package:b/b.dart';"},
        [],
        unused: false,
        entries: [main],
      );
      expect(out, contains('package:b/b.dart'));
      expect(out, isNot(contains('main never imports')));
    });

    group('of a tree artifact', () {
      void tree() {
        for (final name in ['x', 'y']) {
          File('${dir.path}/root/app/gen/$name.dart')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              name == 'y' ? "import 'package:b/b.dart';" : '',
            );
        }
      }

      test('pass when another of its files is reached', () async {
        tree();
        final out = await check(
          {main: "import '../gen/x.dart';"},
          [],
          entries: [main],
          srcDirs: ['app/gen'],
        );
        expect(out, isEmpty);
      });

      test('fail when none is, naming the directory', () async {
        tree();
        final out = await check(
          {main: ''},
          [],
          entries: [main],
          srcDirs: ['app/gen'],
        );
        expect(out, contains('main never imports'));
        expect(out, contains('  ${dir.path}/root/app/gen ('));
      });
    });

    test('are not judged without an entry, as in a library', () async {
      final out = await check({main: '', 'app/test/support.dart': ''}, []);
      expect(out, isEmpty);
    });

    test('are not judged without --check-unused', () async {
      final out = await check(
        {main: '', 'app/test/support.dart': ''},
        [],
        unused: false,
        entries: [main],
      );
      expect(out, isEmpty);
    });
  });

  group('a doc import', () {
    const docImport = "/// @docImport 'package:a/a.dart';\nlibrary;";

    test('uses no dep', () async {
      expect(await check({lib: docImport}, [_a]), contains('\n  //a\n'));
    });

    test('needs no dep', () async {
      expect(await check({lib: docImport}, []), isEmpty);
    });
  });

  group('the analysis options of an executable', () {
    const options = 'analyzer:\n  exclude:\n    - "src/dep.dart"\n';

    test('leave out what its program does not load', () {
      expect(
        optionsExcluding(options, ['app/test/b.dart']),
        'analyzer:\n  exclude:\n    - "src/app/test/b.dart"\n'
        '    - "src/dep.dart"\n',
      );
    });

    test('gain the section when they have none', () {
      expect(
        optionsExcluding('# root\n', ['b.dart']),
        '# root\nanalyzer:\n  exclude:\n    - "src/b.dart"\n',
      );
    });

    test('stay as they are when it loads everything', () {
      expect(optionsExcluding(options, []), options);
    });
  });

  test('without --check-unused nothing is judged', () async {
    expect(await check({lib: ''}, [_a], unused: false), isEmpty);
  });

  test('a malformed --dep is a usage error', () {
    expect(
      check({lib: ''}, [], extra: ['--dep', '//a\tsomething']),
      throwsA(isA<UsageException>()),
    );
  });
}
