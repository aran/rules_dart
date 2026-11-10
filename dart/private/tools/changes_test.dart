// What `bazel run @rules_dart//dart/format` and `@rules_dart//dart/fix` write,
// given the changes files a build made: everything, or with any doubt about
// the workspace, nothing.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'changes.dart';

const _before = 'void main( ){}\n';
const _after = 'void main() {}\n';

void main() {
  late Directory workspace;
  late StringBuffer out;
  late StringBuffer err;
  setUp(() {
    workspace = Directory.systemTemp.createTempSync('ws.');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  File source(String path, [String content = _before]) =>
      File('${workspace.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  Change change(String path, {String from = _before, String to = _after}) =>
      Change(path: path, sha256: digest(utf8.encode(from)), content: to);

  int apply(List<ChangeSet> sets, {bool dryRun = false}) => applyChanges(
    sets,
    workspace: workspace.path,
    dryRun: dryRun,
    verb: 'formatted',
    out: out,
    err: err,
  );

  test('writes the changes of every target', () {
    final a = source('a/lib/a.dart');
    final b = source('b/lib/b.dart');
    final code = apply([
      ChangeSet(target: '//a', changes: [change('a/lib/a.dart')]),
      ChangeSet(target: '//b', changes: [change('b/lib/b.dart')]),
    ]);
    expect(code, 0, reason: '$err');
    expect(a.readAsStringSync(), _after);
    expect(b.readAsStringSync(), _after);
    expect(
      '$out',
      'formatted a/lib/a.dart\n'
          'formatted b/lib/b.dart\n'
          '2 files formatted.\n',
    );
  });

  test('a file changed since the build stops the whole run', () {
    final a = source('a/lib/a.dart');
    final b = source('b/lib/b.dart', 'void main( ) {}\n');
    final code = apply([
      ChangeSet(target: '//a', changes: [change('a/lib/a.dart')]),
      ChangeSet(target: '//b', changes: [change('b/lib/b.dart')]),
    ]);
    expect(code, 1);
    expect(a.readAsStringSync(), _before, reason: 'nothing may be written');
    expect(b.readAsStringSync(), 'void main( ) {}\n');
    expect('$out', isEmpty);
    expect(
      '$err',
      'error: b/lib/b.dart changed after the build read it.\n'
          'Nothing was written. Run again to recompute the changes.\n',
    );
  });

  test('a file deleted since the build stops the whole run', () {
    final a = source('a/lib/a.dart');
    final code = apply([
      ChangeSet(
        target: '//a',
        changes: [change('a/lib/a.dart'), change('a/lib/gone.dart')],
      ),
    ]);
    expect(code, 1);
    expect(a.readAsStringSync(), _before);
    expect('$err', contains('a/lib/gone.dart changed after the build'));
  });

  test('two targets that disagree on a file stop the whole run', () {
    final a = source('lib/a.dart');
    final code = apply([
      ChangeSet(target: '//:one', changes: [change('lib/a.dart')]),
      ChangeSet(
        target: '//:two',
        changes: [change('lib/a.dart', to: 'void main() {\n}\n')],
      ),
    ]);
    expect(code, 1);
    expect(a.readAsStringSync(), _before);
    expect(
      '$err',
      'error: lib/a.dart is formatted differently by //:one and //:two.\n'
          'Nothing was written. Run them one at a time.\n',
    );
  });

  test('two targets that agree on a file write it once', () {
    final a = source('lib/a.dart');
    final code = apply([
      ChangeSet(target: '//:one', changes: [change('lib/a.dart')]),
      ChangeSet(target: '//:two', changes: [change('lib/a.dart')]),
    ]);
    expect(code, 0, reason: '$err');
    expect(a.readAsStringSync(), _after);
    expect('$out', 'formatted lib/a.dart\n1 file formatted.\n');
  });

  test('a dry run prints the diff and writes nothing', () {
    final a = source('lib/a.dart', '// x\n$_before');
    final code = apply([
      ChangeSet(
        target: '//:lib',
        changes: [
          change('lib/a.dart', from: '// x\n$_before', to: '// x\n$_after'),
        ],
      ),
    ], dryRun: true);
    expect(code, 0, reason: '$err');
    expect(a.readAsStringSync(), '// x\n$_before');
    expect(
      '$out',
      '--- a/lib/a.dart\n'
          '+++ b/lib/a.dart\n'
          '@@ -1,2 +1,2 @@\n'
          ' // x\n'
          '-void main( ){}\n'
          '+void main() {}\n'
          '1 file would be formatted (dry run, nothing written).\n',
    );
  });

  test('a path outside the workspace is refused', () {
    final code = apply([
      ChangeSet(target: '//:lib', changes: [change('../escape.dart')]),
    ]);
    expect(code, 1);
    expect('$err', contains('not a path inside the workspace'));
  });

  test('generated files are reported, not written', () {
    source('lib/a.dart');
    final code = apply([
      ChangeSet(
        target: '//:lib',
        changes: [change('lib/a.dart')],
        dropped: ['bazel-out/k8-fastbuild/bin/lib/a.g.dart'],
      ),
    ]);
    expect(code, 0, reason: '$err');
    expect('$err', contains('lib/a.g.dart is generated'));
  });

  test('a changes file round-trips', () {
    final path = '${workspace.path}/changes.json';
    ChangeSet(
      target: '//:lib',
      changes: [change('lib/b.dart'), change('lib/a.dart')],
      dropped: ['x.g.dart'],
    ).write(path);
    final read = ChangeSet.read(path);
    expect(read.target, '//:lib');
    expect(
      [for (final c in read.changes) c.path],
      ['lib/a.dart', 'lib/b.dart'],
    );
    expect(read.changes.first.content, _after);
    expect(read.dropped, ['x.g.dart']);
  });
}
