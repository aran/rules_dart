import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'copy_tree.dart' as tree;

/// Unit tests for `copy_tree`'s destination rules and copying. Each case writes
/// real files under a temp directory, plans and copies them, and checks where
/// they land. The expected paths are copy_to_directory's (bazel-lib 3.7.2).

late Directory tmp;

String get dst => '${tmp.path}/out';

/// Writes `tmp/src/<shortPath>` and returns the record for it. `workspace` and
/// `workspacePath` default to the main repository's values for `shortPath`.
List<String> src(
  String shortPath,
  List<int> bytes, {
  String workspace = '',
  String? workspacePath,
}) {
  final path = '${tmp.path}/src/$shortPath';
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return [path, shortPath, workspace, workspacePath ?? shortPath];
}

List<String> text(String shortPath, String content) =>
    src(shortPath, content.codeUnits);

/// The params file lines, as the rule writes them.
List<String> params({
  List<String> roots = const [],
  Map<String, String> replace = const {},
  List<String> external = const [],
  String workspace = '',
  required List<List<String>> files,
}) => [
  dst,
  for (final r in roots) ...['--root', r],
  for (final e in replace.entries) ...['--replace', e.key, e.value],
  for (final e in external) ...['--external', e],
  '--workspace',
  workspace,
  for (final f in files) ...['--file', ...f],
];

Future<void> run(List<String> lines) async =>
    tree.copyTree(tree.parseRequest(lines));

/// The copied files under [dst], as `relative path -> content`.
Map<String, String> copied() {
  final out = <String, String>{};
  final root = Directory(dst);
  if (!root.existsSync()) return out;
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    out[f.path.substring(dst.length + 1).replaceAll('\\', '/')] = f
        .readAsStringSync();
  }
  return out;
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('copy_tree_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('destinations', () {
    test('root "" (the root package) keeps workspace paths', () async {
      await run(
        params(
          roots: [''],
          files: [text('lib/a.dart', 'a'), text('tool/b.dart', 'b')],
        ),
      );
      expect(copied(), {'lib/a.dart': 'a', 'tool/b.dart': 'b'});
    });

    test('a root path is stripped; a file outside it keeps its path', () async {
      await run(
        params(
          roots: ['pkg'],
          files: [text('pkg/lib/a.dart', 'a'), text('other/x.dart', 'x')],
        ),
      );
      expect(copied(), {'lib/a.dart': 'a', 'other/x.dart': 'x'});
    });

    test('the longest matching root wins', () async {
      await run(
        params(
          roots: ['pkg', 'pkg/lib'],
          files: [text('pkg/lib/src/a.dart', 'a')],
        ),
      );
      expect(copied(), {'src/a.dart': 'a'});
    });

    test(
      'a root matches a directory prefix, as copy_to_directory does',
      () async {
        // Go's longestGlobMatch tries every prefix of the directory, so "lib"
        // also strips the start of "libx". copy_to_directory does the same.
        await run(params(roots: ['lib'], files: [text('libx/a.dart', 'a')]));
        expect(copied(), {'x/a.dart': 'a'});
      },
    );

    test('glob roots match as doublestar does', () async {
      await run(
        params(
          roots: ['*/lib'],
          files: [text('a/lib/x.dart', 'x'), text('a/b/lib/y.dart', 'y')],
        ),
      );
      expect(copied(), {'x.dart': 'x', 'a/b/lib/y.dart': 'y'});
    });

    test('replace_prefixes rewrites the matching prefix', () async {
      await run(
        params(
          replace: {'gen/stub': 'lib'},
          files: [text('gen/stub/pubspec.yaml', 'name: p')],
        ),
      );
      expect(copied(), {'lib/pubspec.yaml': 'name: p'});
    });

    test('the longest replace key wins', () async {
      await run(
        params(
          replace: {'gen': 'g', 'gen/stub': 'lib'},
          files: [text('gen/stub/a.dart', 'a'), text('gen/other/b.dart', 'b')],
        ),
      );
      expect(copied(), {'lib/a.dart': 'a', 'g/other/b.dart': 'b'});
    });

    test('a replace key may end inside a segment', () async {
      await run(
        params(
          replace: {'gen/stub': 'lib'},
          files: [text('gen/stubs/a.dart', 'a')],
        ),
      );
      expect(copied(), {'libs/a.dart': 'a'});
    });

    test('replace runs after root stripping', () async {
      await run(
        params(
          roots: ['pkg'],
          replace: {'lib': 'src'},
          files: [text('pkg/lib/a.dart', 'a')],
        ),
      );
      expect(copied(), {'src/a.dart': 'a'});
    });

    test(
      'a path with spaces and an empty record survive the params file',
      () async {
        await run(params(roots: [''], files: [text('my dir/a b.dart', 'sp')]));
        expect(copied(), {'my dir/a b.dart': 'sp'});
      },
    );
  });

  group('include_external_repositories', () {
    test(
      'an external file is excluded unless its repository matches',
      () async {
        final files = [
          src(
            '../pub_x/lib/a.dart',
            'a'.codeUnits,
            workspace: 'pub_x',
            workspacePath: 'lib/a.dart',
          ),
        ];
        await run(params(files: files));
        expect(copied(), isEmpty);

        await run(params(external: ['other*'], files: files));
        expect(copied(), isEmpty);

        await run(params(external: ['pub_*'], files: files));
        expect(copied(), {'lib/a.dart': 'a'});
      },
    );

    test('a glob of * matches every repository', () async {
      await run(
        params(
          external: ['*'],
          files: [
            src(
              '../pub_a/lib/a.dart',
              'a'.codeUnits,
              workspace: 'pub_a',
              workspacePath: 'lib/a.dart',
            ),
            src(
              '../pub_b/lib/b.dart',
              'b'.codeUnits,
              workspace: 'pub_b',
              workspacePath: 'lib/b.dart',
            ),
          ],
        ),
      );
      expect(copied(), {'lib/a.dart': 'a', 'lib/b.dart': 'b'});
    });

    test('a file of the target repository needs no pattern', () async {
      await run(
        params(
          workspace: 'pub_x',
          files: [
            src(
              '../pub_x/lib/a.dart',
              'a'.codeUnits,
              workspace: 'pub_x',
              workspacePath: 'lib/a.dart',
            ),
          ],
        ),
      );
      expect(copied(), {'lib/a.dart': 'a'});
    });

    test('a file with an empty repository name is always included', () async {
      await run(params(files: [text('lib/a.dart', 'a')]));
      expect(copied(), {'lib/a.dart': 'a'});
    });
  });

  group('tree artifact children', () {
    test(
      'children placed as records copy their bytes under the directory',
      () async {
        // A tree artifact expands to one record per file, with the directory's
        // repository-relative path as the prefix of each child's path.
        await run(
          params(
            roots: ['pkg'],
            files: [
              text('pkg/tree/a.dart', 'a'),
              text('pkg/tree/sub/b.dart', 'b'),
            ],
          ),
        );
        expect(copied(), {'tree/a.dart': 'a', 'tree/sub/b.dart': 'b'});
      },
    );
  });

  group('collisions', () {
    test(
      'two files with one destination and different short paths fail',
      () async {
        // Both land at `x.dart`: `a/` and `b/` are roots.
        await expectLater(
          run(
            params(
              roots: ['a', 'b'],
              files: [text('a/x.dart', '1'), text('b/x.dart', '2')],
            ),
          ),
          throwsA(isA<tree.CopyError>()),
        );
      },
    );

    test(
      'the same file listed twice (source and copy) is copied once',
      () async {
        // Same short path and size: the source file and its generated copy.
        await run(
          params(
            files: [
              text('lib/a.dart', 'abc'),
              src('lib/a.dart', 'abc'.codeUnits),
            ],
          ),
        );
        expect(copied(), {'lib/a.dart': 'abc'});
      },
    );

    test('a collision is reported before anything is copied', () async {
      await expectLater(
        run(
          params(
            roots: ['a', 'b'],
            files: [
              text('lib/z.dart', 'z'),
              text('a/x.dart', '1'),
              text('b/x.dart', '2'),
            ],
          ),
        ),
        throwsA(isA<tree.CopyError>()),
      );
      expect(File('$dst/lib/z.dart').existsSync(), isFalse);
      expect(copied(), isEmpty);
    });
  });

  group('contents', () {
    test('bytes are copied unchanged, including CRLF and high bytes', () async {
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 256; i++) i,
        13,
        10,
      ]);
      await run(params(files: [src('lib/bin.dat', bytes)]));
      expect(File('$dst/lib/bin.dat').readAsBytesSync(), bytes);
    });

    test('an empty file is copied', () async {
      await run(params(files: [src('lib/empty.dart', const [])]));
      expect(File('$dst/lib/empty.dart').existsSync(), isTrue);
      expect(File('$dst/lib/empty.dart').lengthSync(), 0);
    });
  });

  group('params file', () {
    test('an unknown record is an error', () {
      expect(
        () => tree.parseRequest([dst, '--bogus']),
        throwsA(isA<FormatException>()),
      );
    });

    test('a record cut short is an error', () {
      expect(
        () => tree.parseRequest([dst, '--file', 'a', 'b']),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('globs', () {
    test('an unclosed class is an error, not a silent mismatch', () async {
      await expectLater(
        run(params(roots: ['[ab'], files: [text('a/x.dart', 'x')])),
        throwsA(isA<FormatException>()),
      );
    });

    test('braces select alternatives', () async {
      await run(
        params(
          roots: ['{a,b}/lib'],
          files: [
            text('a/lib/x.dart', 'x'),
            text('b/lib/y.dart', 'y'),
            text('c/lib/z.dart', 'z'),
          ],
        ),
      );
      expect(copied(), {'x.dart': 'x', 'y.dart': 'y', 'c/lib/z.dart': 'z'});
    });

    test('a ** segment spans directories, including none', () async {
      await run(
        params(
          roots: ['pkg/**/lib'],
          files: [text('pkg/lib/a.dart', 'a'), text('pkg/x/y/lib/b.dart', 'b')],
        ),
      );
      expect(copied(), {'a.dart': 'a', 'b.dart': 'b'});
    });

    test('a class negated with ! excludes its characters', () async {
      await run(
        params(
          roots: ['[!a]'],
          files: [text('b/x.dart', 'x'), text('a/y.dart', 'y')],
        ),
      );
      expect(copied(), {'x.dart': 'x', 'a/y.dart': 'y'});
    });

    test('escapes match the metacharacter itself', () async {
      await run(
        params(
          roots: [r'a\*'],
          files: [text('a*/x.dart', 'x'), text('abc/y.dart', 'y')],
        ),
      );
      expect(copied(), {'x.dart': 'x', 'abc/y.dart': 'y'});
    });
  });
}
