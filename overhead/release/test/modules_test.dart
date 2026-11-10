import 'dart:io';

import 'package:test/test.dart';

import '../modules.dart';

/// Which modules a release names in its install snippet: every root in
/// `.bcr/config.yml`, or the repository's own module when there is one.
void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('modules');
    addTearDown(() => repo.deleteSync(recursive: true));
  });

  void write(String path, String content) => File('${repo.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  group('a repository publishing one module', () {
    const snippet = '''
Add to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_x", version = "1.2.3")
```

''';

    setUp(() => write('MODULE.bazel', 'module(\n    name = "rules_x",\n)\n'));

    test('without a .bcr/config.yml', () {
      expect(installSnippet(releasedModules(repo.path), '1.2.3'), snippet);
    });

    test('with a config naming no roots', () {
      write('.bcr/config.yml', 'fixedReleaser:\n  login: someone\n');
      expect(installSnippet(releasedModules(repo.path), '1.2.3'), snippet);
    });

    test('with a config naming the root alone', () {
      write('.bcr/config.yml', 'moduleRoots: ["."]\n');
      expect(installSnippet(releasedModules(repo.path), '1.2.3'), snippet);
    });
  });

  group('a repository publishing several modules', () {
    setUp(() {
      write('MODULE.bazel', 'module(name = "rules_x")\n');
      write(
        'gazelle/MODULE.bazel',
        'module(name = "rules_x_gazelle_plugin")\n',
      );
    });

    test('lists each, in moduleRoots order', () {
      write(
        '.bcr/config.yml',
        '# Released together.\nmoduleRoots: [".", "gazelle"]  # both\n',
      );
      expect(installSnippet(releasedModules(repo.path), '1.2.3'), '''
Add to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_x", version = "1.2.3")
bazel_dep(name = "rules_x_gazelle_plugin", version = "1.2.3")
```

''');
    });

    test('reads a block sequence', () {
      write(
        '.bcr/config.yml',
        'moduleRoots:\n  - gazelle\n  # the root\n  - "."\nfixedReleaser: x\n',
      );
      expect(releasedModules(repo.path), ['rules_x_gazelle_plugin', 'rules_x']);
    });

    test('a root without a MODULE.bazel is an error', () {
      write('.bcr/config.yml', 'moduleRoots: [".", "missing"]\n');
      expect(
        () => releasedModules(repo.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('missing has no MODULE.bazel'),
          ),
        ),
      );
    });

    test('a MODULE.bazel without a name is an error', () {
      write('gazelle/MODULE.bazel', 'bazel_dep(name = "rules_x")\n');
      write('.bcr/config.yml', 'moduleRoots: [".", "gazelle"]\n');
      expect(() => releasedModules(repo.path), throwsFormatException);
    });
  });

  group('moduleRoots refuses what it cannot read', () {
    for (final config in [
      'moduleRoots: []\n',
      'moduleRoots:\n',
      'moduleRoots: [".",\n  "gazelle"]\n',
      'moduleRoots: gazelle\n',
      'moduleRoots: [{a: b}]\n',
    ]) {
      test(config.replaceAll('\n', r'\n'), () {
        expect(() => moduleRoots(config), throwsFormatException);
      });
    }
  });
}
