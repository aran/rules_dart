import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Where `ws/analysis_options.yaml` governs, by its workspace path.
const _governed = 'dart/tests/format_run_fixture/ws';

// Formatted for a 100-column page with trailing commas preserved: at stock
// defaults the long call wraps and `g(1,)` collapses onto one line.
const _wide = '''
void f(int Function(int, int, int) someFunction) {
  final result = someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree);
  g(
    1,
  );
}

void h() {}
''';

// The same code at stock defaults.
const _stock = '''
void f(int Function(int, int, int) someFunction) {
  final result = someFunction(
    argumentNumberOne,
    argumentNumberTwo,
    argumentNumberThree,
  );
  g(1);
}

void h() {}
''';

void main(List<String> args) {
  final r = Runfiles.create();
  final format = r.rlocation(args[0]);
  final config = args[1];

  late Directory workspace;
  setUp(() => workspace = Directory.systemTemp.createTempSync('ws.'));
  tearDown(() => workspace.deleteSync(recursive: true));

  ProcessResult run(List<String> operands, {String? cwd}) => Process.runSync(
    format,
    operands,
    environment: {
      'BUILD_WORKSPACE_DIRECTORY': workspace.path,
      'BUILD_WORKING_DIRECTORY': cwd ?? workspace.path,
      'DART_FORMAT_CONFIG': config,
    },
  );

  File write(String path, String content) => File('${workspace.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  test('formats each file under its nearest listed options', () {
    final governed = write(
      '$_governed/lib/a.dart',
      _wide.replaceFirst('void h() {}', 'void  h( ){}'),
    );
    // Governed by `ws/sub/analysis_options.yaml`, which includes the parent
    // by relative path: it must get the parent's settings.
    final nested = write(
      '$_governed/sub/lib/n.dart',
      _wide.replaceFirst('void h() {}', 'void  h( ){}'),
    );
    final elsewhere = write('other/b.dart', _wide);

    final result = run(['$_governed/lib', '$_governed/sub', 'other']);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, isNot(contains('Warning')));
    expect(governed.readAsStringSync(), _wide);
    expect(nested.readAsStringSync(), _wide);
    expect(elsewhere.readAsStringSync(), _stock);
  });

  test('refuses options that include an undeclared file', () {
    // Present in the workspace, and declared by no target: reading it would
    // let the run disagree with the check.
    write(
      '$_governed/undeclared/shared.yaml',
      'formatter:\n  page_width: 20\n',
    );
    final file = write('$_governed/undeclared/lib/u.dart', 'void  h( ){}\n');

    final result = run(['$_governed/undeclared/lib']);

    expect(result.exitCode, 1);
    // Named at its workspace path, not the scratch copy's.
    expect(
      result.stderr,
      contains('Couldn\'t read file "$_governed/undeclared/shared.yaml"'),
    );
    expect(file.readAsStringSync(), 'void  h( ){}\n');
  });

  test('resolves operands against the directory it was run from', () {
    final file = write('$_governed/lib/a.dart', 'void  h( ){}\n');

    final result = run(['lib'], cwd: '${workspace.path}/$_governed');

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      result.stdout,
      contains('Formatted lib${Platform.pathSeparator}a.dart'),
    );
    expect(file.readAsStringSync(), 'void h() {}\n');
  });

  test('refuses a file outside the workspace', () {
    final outside = Directory.systemTemp.createTempSync('outside.');
    addTearDown(() => outside.deleteSync(recursive: true));
    final file = File('${outside.path}/c.dart')
      ..writeAsStringSync('void  h( ){}\n');

    final result = run([file.path]);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('outside the workspace'));
    expect(file.readAsStringSync(), 'void  h( ){}\n');
  });
}
