// The unused-dependency check: every entry of a target's `deps` is named by
// an import or export of one of its files. Driven through `runCheck`, as the
// Bazel action runs it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'kernel_tool/args.dart';
import 'kernel_tool/check_command.dart';

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
