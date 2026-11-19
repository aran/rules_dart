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

void main() {
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
