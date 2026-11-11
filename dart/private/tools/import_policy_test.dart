// The import check's property: a target compiles only from files it declares.
//
// Every `import`, `export` and `part` of a checked library must, however it is
// spelled, either name a `dart:` library, or resolve (the way the COMPILER
// resolves it, not the way our tooling canonicalises it) to a file the target
// holds, or to a `package:` URI a declared dependency provides. Every other
// spelling that could reach a file is refused, because the compiler reads it
// from wherever it finds it: from the host (`file:`), from the exec root in an
// unsandboxed worker, or as a second copy of a library whose real URI is
// `package:...` (a relative path into `lib/`).
//
// These tests drive `runCheck` as the Bazel action does, so they hold for any
// implementation of the rule, not only today's `checkPolicy`.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'kernel_tool/args.dart';
import 'kernel_tool/check_command.dart';

const _packageConfig = {
  'configVersion': 2,
  'packages': [
    {
      'name': 'app',
      'rootUri': 'org-dartlang-root:///app/',
      'packageUri': 'lib/',
    },
    {'name': 'rel', 'rootUri': '../rel', 'packageUri': 'lib/'},
    {'name': 'dep', 'rootUri': '../dep', 'packageUri': 'lib/'},
    {'name': 'indirect', 'rootUri': '../indirect', 'packageUri': 'lib/'},
  ],
};

typedef _Case = (String path, String text, Map<String, String> more);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('import_policy_'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Runs `check` on target `//app:t` (package `app`; `rel` and `dep` are
  /// declared deps) with the files [srcs] (root-relative path to text) and the
  /// dependency files [deps] (root-relative paths). Returns the diagnostics,
  /// empty when it passes.
  Future<String> check(
    Map<String, String> srcs, {
    List<String> deps = const [
      'rel/lib/r.dart',
      'dep/lib/d.dart',
      'app/lib/b.dart',
    ],
    bool layering = false,
  }) async {
    File write(String rel, String text) => File('${dir.path}/root/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    write('app/pc.json', jsonEncode(_packageConfig));
    final args = [
      '--label',
      '//app:t',
      '--package-config',
      '${dir.path}/root/app/pc.json',
      '--package-name',
      'app',
      '--package-root',
      'app',
      '--multi-root',
      '${dir.path}/root',
      for (final e in srcs.entries) ...['--src', write(e.key, e.value).path],
      for (final d in deps) ...['--dep-file', write(d, '').path],
      for (final p in ['rel', 'dep']) ...['--available-package', p],
      if (layering) ...[
        '--check-layering',
        '--direct-package',
        'rel',
        '--direct-package',
        'dep',
        '--available-package',
        'indirect',
      ],
      '--output',
      '${dir.path}/stamp',
    ];
    final err = StringBuffer();
    final code = await runCheck(Args.parse('check', args), err: err);
    expect(File('${dir.path}/stamp').existsSync(), code == 0);
    return code == 0 ? '' : err.toString();
  }

  // A test of the own package (the common footgun: tests sit outside lib/).
  const t = 'app/test/t.dart';
  const lib = 'app/lib/a.dart';

  group('accepts', () {
    // Controls: the property must not over-refuse.
    final ok = <String, _Case>{
      'dart: libraries': (lib, "import 'dart:io'; import 'dart:ffi';", {}),
      'a declared package': (
        lib,
        "import 'package:dep/d.dart'; export 'package:rel/r.dart';",
        {},
      ),
      'the own package by package: URI': (
        lib,
        "import 'package:app/b.dart';",
        {},
      ),
      'a relative sibling inside lib/': (lib, "import 'b.dart';", {}),
      'a relative path into a subdirectory of lib/': (
        lib,
        "import 'src/c.dart';",
        {'app/lib/src/c.dart': ''},
      ),
      'a relative path that leaves and re-enters lib/ inside it': (
        'app/lib/src/c.dart',
        "import '../b.dart';",
        {},
      ),
      'a held helper beside a test, outside lib/': (
        t,
        "import 'helper.dart';",
        {'app/test/helper.dart': ''},
      ),
      'a held part': (
        lib,
        "part 'a.g.dart';",
        {'app/lib/a.g.dart': "part of 'a.dart';"},
      ),
      // ffigen writes this to name the library's own declarations.
      "the library's own URI, written as '' (lib/)": (
        lib,
        "import '' as self;",
        {},
      ),
      "the library's own URI, written as '' (outside lib/)": (
        t,
        "import '' as self;",
        {},
      ),
      'a conditional import whose every branch is declared': (
        lib,
        "import 'b.dart' if (dart.library.io) 'package:dep/d.dart';",
        {},
      ),
    };
    for (final e in ok.entries) {
      test(e.key, () async {
        final (path, text, more) = e.value;
        expect(await check({path: text, ...more}), isEmpty);
      });
    }
  });

  group('refuses a spelling that reaches a file the target does not declare', () {
    final bad = <String, _Case>{
      // Claim 1: a relative path into lib/. The compiler sees the file as
      // `org-dartlang-root:///...`, a library different from
      // `package:app/b.dart`, which is what its dependency's module holds.
      'a relative path from a test into the own lib/ (import)': (
        t,
        "import '../lib/b.dart';",
        {},
      ),
      'a relative path from a test into the own lib/ (export)': (
        t,
        "export '../lib/b.dart';",
        {},
      ),
      'a relative path from lib/ out and back into lib/': (
        'app/lib/src/c.dart',
        "import '../../lib/b.dart';",
        {},
      ),
      "a relative path from a test into a declared package's lib/": (
        t,
        "import '../../rel/lib/r.dart';",
        {},
      ),
      'the org-dartlang-root: URI of a lib/ file': (
        t,
        "import 'org-dartlang-root:///app/lib/b.dart';",
        {},
      ),
      // Claim 2: imports with no package.
      'a file: URI': (t, "import 'file:///etc/hosts.dart';", {}),
      'a file: URI in an export': (lib, "export 'file:///x/y.dart';", {}),
      'a file: URI in one branch of a conditional import': (
        lib,
        "import 'b.dart' if (dart.library.io) 'file:///x/y.dart';",
        {},
      ),
      'an unknown scheme': (t, "import 'http://example.com/x.dart';", {}),
      'a data: URI': (t, "import 'data:text/plain,void main(){}';", {}),
      'a relative path leaving every declared package': (
        t,
        "import '../../shared/x.dart';",
        {},
      ),
      'a relative path above the exec root': (
        t,
        "import '../../../../../x.dart';",
        {},
      ),
      'a relative path to an undeclared file beside a test': (
        t,
        "import 'undeclared_helper.dart';",
        {},
      ),
      'a package: URI climbing out of its package': (
        t,
        "import 'package:app/../test/t2.dart';",
        {'app/test/t2.dart': ''},
      ),
      'a package: URI climbing out into another package': (
        t,
        "import 'package:dep/../../shared/x.dart';",
        {},
      ),
      'a package: URI climbing out by an encoded ..': (
        t,
        "import 'package:app/%2e%2e/test/t2.dart';",
        {'app/test/t2.dart': ''},
      ),
      'a package: URI with an encoded separator': (
        t,
        "import 'package:app%2F..%2Ftest/t2.dart';",
        {'app/test/t2.dart': ''},
      ),
      // Parts compile into the library's own module: the target must hold them.
      'a part the target does not hold': (lib, "part 'missing.g.dart';", {}),
      'a part that is a dependency\'s file': (lib, "part 'b.dart';", {}),
      'a part outside every declared package': (
        lib,
        "part '../../shared/p.dart';",
        {},
      ),
      'a part by file: URI': (lib, "part 'file:///x/p.dart';", {}),
      // A query or fragment makes another URI for the same file, which the
      // compiler loads as a second copy of the library.
      'a relative path with a query': (lib, "import 'b.dart?v=2';", {}),
      'a relative path with a fragment': (lib, "import 'b.dart#x';", {}),
      'a package: URI with a query': (
        lib,
        "import 'package:dep/d.dart?x';",
        {},
      ),
      'a dart: URI with a fragment': (lib, "import 'dart:io#x';", {}),
      'the own URI with a query': (lib, "import '?x' as self;", {}),
    };
    for (final e in bad.entries) {
      test(e.key, () async {
        final (path, text, more) = e.value;
        expect(
          await check({path: text, ...more}),
          isNotEmpty,
          reason: 'the check passed `$text` in $path',
        );
      });
    }

    test(
      'and the refusal of a relative path into lib/ names the package: URI',
      () async {
        final err = await check({t: "import '../lib/b.dart';"});
        expect(err, contains('package:app/b.dart'));
      },
    );

    // Two spellings that were refused before for the wrong reason, as a file
    // of the own package no dependency compiles: the refusal must say what
    // the compiler really reads, and name the fix.
    test('a relative path out of lib/ and back is refused as climbing out, '
        'naming the package: URI', () async {
      final err = await check({
        'app/lib/src/c.dart': "import '../../lib/b.dart';",
      });
      expect(err, contains('climbs out of lib/'));
      expect(err, contains("'package:app/b.dart'"));
    });

    test(
      'a query or fragment is refused as a second copy of the library',
      () async {
        for (final written in ['b.dart?v=2', 'package:dep/d.dart#x']) {
          final err = await check({lib: "import '$written';"});
          expect(err, contains('a query or fragment'), reason: written);
        }
      },
    );

    test('a package: URI with .. is refused as leaving its package', () async {
      final err = await check({
        t: "import 'package:app/../test/t2.dart';",
        'app/test/t2.dart': '',
      });
      expect(err, contains('does not stay inside one package'));
    });

    test('a relative path must not escape the layering check', () async {
      final err = await check({
        t: "import '../../indirect/lib/i.dart';",
      }, layering: true);
      expect(err, isNotEmpty);
    });

    test('a file of a declared package that no dependency holds', () async {
      // Sharpened beyond the report (contestable: it needs the dependency
      // file list to be complete for every package): the same hole as an own
      // file no dependency compiles, which is refused today.
      final err = await check({lib: "import 'package:dep/ghost.dart';"});
      expect(err, isNotEmpty);
    });
  });
}
