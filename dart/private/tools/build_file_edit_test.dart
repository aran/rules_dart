import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'build_file_edit.dart';

const _formatted = '''
alias(
    name = "other",
    actual = ":a",
)

dart_library(
    name = "lib",
    srcs = ["lib/lib.dart"],
    deps = [
        ":a",
        ":b",
    ],
)
''';

const _edited = '''
alias(
    name = "other",
    actual = ":a",
)

dart_library(
    name = "lib",
    srcs = ["lib/lib.dart"],
    deps = [":b"],
)
''';

/// The first argument is buildozer's runfiles path.
void main(List<String> args) {
  group('with buildozer, a label written as', () {
    final buildozer = Runfiles.create().rlocation(args.first);
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('build_file_edit'));
    tearDown(() => root.deleteSync(recursive: true));

    File buildFile() => File('${root.path}/app/sub/BUILD.bazel');

    /// Runs buildozer on the copy under [root], returning the file it leaves.
    String run(List<String> command) {
      final result = Process.runSync(buildozer, [
        ...command,
      ], workingDirectory: root.path);
      expect(result.exitCode, anyOf(0, 3), reason: '${result.stderr}');
      return buildFile().readAsStringSync();
    }

    for (final label in const [
      // Shortened by buildifier.
      '@xml//:xml',
      '@repo//pkg:pkg',
      '@repo//a/pkg:pkg',
      '//app/sub:sub',
      '//a/b:b',
      // The short forms themselves.
      '@xml',
      '@repo//pkg',
      '//a/b',
      // Not shortened: a canonical repository, or a name buildifier's pattern
      // for a repository does not take.
      '@@canonical//:canonical',
      '@@canonical',
      '@@canon+//pkg:pkg',
      '@@+ext+repo//:repo',
      '@a-b//:a-b',
      '@a.b//:a.b',
      '@//app:app',
      '@@//app:app',
      // A target named otherwise than its package.
      '@repo//pkg:other',
      '@repo//:other',
      '//app:other',
      '//:root',
      '//a:a/b',
      '@r//a/b:b/b',
      // In the package.
      ':local',
      'bare',
    ]) {
      test('$label is removed from a file buildifier would change', () {
        File('${root.path}/MODULE.bazel').writeAsStringSync('');
        final original = 'x(name="lib",\n  deps=["$label", ":keep"])\n';
        buildFile()
          ..createSync(recursive: true)
          ..writeAsStringSync(original);
        final formatted = run(['format', '//app/sub:__pkg__']);
        final edited = run(['remove deps $label', '//app/sub:lib']);
        expect(edited, isNot(formatted), reason: 'buildozer removed nothing');

        final made = applyRemovals(
          original: original,
          formatted: formatted,
          edited: edited,
        );
        expect(made, 'x(name="lib",\n  deps=[":keep"])\n');

        buildFile().writeAsStringSync(made!);
        expect(sameBuild(run(['format', '//app/sub:__pkg__']), edited), isTrue);
      });
    }
  });

  test('takes one label for its spellings, and no other label for it', () {
    const formatted = 'x(\n    name = "lib",\n    deps = ["@xml", ":c"],\n)\n';
    const edited = 'x(\n    name = "lib",\n    deps = [":c"],\n)\n';
    String? removing(String list) => applyRemovals(
      original: 'x(name="lib", deps=$list)\n',
      formatted: formatted,
      edited: edited,
    );
    expect(removing('["@xml//:xml", ":c"]'), 'x(name="lib", deps=[":c"])\n');
    // Each names another target.
    expect(removing('["@xml//:other", ":c"]'), isNull);
    expect(removing('["@xml//xml", ":c"]'), isNull);
    expect(removing('["@@xml", ":c"]'), isNull);
  });

  test('removes a dep on its own line and touches nothing else', () {
    expect(
      applyRemovals(
        original: '''
alias(name="other",   actual=":a")

dart_library(name = "lib",
  srcs=[ "lib/lib.dart" ],
  deps = [
      ":a",  # why
      ":b",
  ])
''',
        formatted: _formatted,
        edited: _edited,
      ),
      '''
alias(name="other",   actual=":a")

dart_library(name = "lib",
  srcs=[ "lib/lib.dart" ],
  deps = [
      ":b",
  ])
''',
    );
  });

  test('removes the comment lines above a dep with it', () {
    expect(
      applyRemovals(
        original: '''
dart_library(name="lib",
    deps = [
        # Needed once.
        # Not now.
        ":a",
        ":b",
    ])
''',
        formatted: _formatted,
        edited: _edited,
      ),
      '''
dart_library(name="lib",
    deps = [
        ":b",
    ])
''',
    );
  });

  test('removes from a list on one line, first or last', () {
    String? edit(String list) => applyRemovals(
      original: 'dart_library(name="lib", deps=$list)\n',
      formatted: _formatted,
      edited: _edited,
    );
    expect(edit('[":a", ":b"]'), 'dart_library(name="lib", deps=[":b"])\n');
    expect(edit('[":b", ":a"]'), 'dart_library(name="lib", deps=[":b"])\n');
  });

  test('removes the attribute with its last dep', () {
    const formatted = 'x(\n    name = "lib",\n    deps = [":a"],\n)\n';
    const edited = 'x(\n    name = "lib",\n)\n';
    expect(
      applyRemovals(
        original: 'x(name="lib",\n    deps = [\n        ":a",\n    ],\n)\n',
        formatted: formatted,
        edited: edited,
      ),
      'x(name="lib",\n)\n',
    );
  });

  test('keeps what a select() branch is keyed by', () {
    const formatted = '''
x(
    name = "lib",
    deps = select({
        ":a": [":a"],
        "//conditions:default": [],
    }),
)
''';
    const edited = '''
x(
    name = "lib",
    deps = select({
        ":a": [],
        "//conditions:default": [],
    }),
)
''';
    expect(
      applyRemovals(
        original:
            'x(name="lib", deps=select({":a": [":a"], '
            '"//conditions:default": []}))\n',
        formatted: formatted,
        edited: edited,
      ),
      'x(name="lib", deps=select({":a": [], "//conditions:default": []}))\n',
    );
  });

  test('finds a label buildifier shortens', () {
    const formatted = 'x(\n    name = "lib",\n    deps = ["//a/b", ":c"],\n)\n';
    const edited = 'x(\n    name = "lib",\n    deps = [":c"],\n)\n';
    expect(
      applyRemovals(
        original: 'x(name="lib", deps=["//a/b:b", ":c"])\n',
        formatted: formatted,
        edited: edited,
      ),
      'x(name="lib", deps=[":c"])\n',
    );
  });

  test('is not confused by quotes in comments and strings', () {
    expect(
      applyRemovals(
        original: '''
# it's a "comment
y(name="s", doc = """ deps = [":a"] """)
dart_library(name="lib", deps=[":a", ":b"])
''',
        formatted: _formatted,
        edited: _edited,
      ),
      '''
# it's a "comment
y(name="s", doc = """ deps = [":a"] """)
dart_library(name="lib", deps=[":b"])
''',
    );
  });

  test('sameBuild ignores layout and comments, and nothing else', () {
    const lines =
        'x(\n    name = "a",\n    deps = [\n        ":b",\n    ],\n)\n';
    expect(
      sameBuild(lines, 'x(\n    name = "a",\n    deps = [":b"],\n)\n'),
      isTrue,
    );
    expect(sameBuild(lines, '# why\n$lines'), isTrue);
    expect(sameBuild(lines, lines.replaceFirst(':b', ':c')), isFalse);
    expect(sameBuild(lines, '$lines\ny(name = "z")\n'), isFalse);
  });

  test('answers null for a dep the file does not state', () {
    expect(
      applyRemovals(
        original: 'dart_library(name="lib", deps=[":b"])\n',
        formatted: _formatted,
        edited: _edited,
      ),
      isNull,
    );
    expect(
      applyRemovals(
        original: 'y(name="unrelated")\n',
        formatted: _formatted,
        edited: _edited,
      ),
      isNull,
    );
  });
}
