// The reader against the conformance fixture in `conformance/`: read in that
// directory, `program.params` lists what `expected.txt` says, and
// `code_names.params` what `code_names.expected.txt` says, through the library
// and through the `list` tool. A reader of the format in another language
// checks itself against the same files.
import 'dart:io';

import 'package:program_assets/program_assets.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late final Directory fixture;
late final String list;

String _normalized(String text) => text.replaceAll(r'\', '/');

void main(List<String> args) {
  setUpAll(() {
    // The fixture's files, copied to where its relative paths hold. Runfiles
    // may be a manifest and not a tree, so each is found on its own.
    final runfiles = Runfiles.create();
    list = runfiles.rlocation(Platform.environment['LIST_TOOL']!);
    fixture = Directory.systemTemp.createTempSync('program_assets_');
    for (final path in Platform.environment['CONFORMANCE']!.split(' ')) {
      final relative = path.substring(
        path.indexOf('conformance/') + 'conformance/'.length,
      );
      final copy = File('${fixture.path}/$relative')
        ..parent.createSync(recursive: true);
      File(runfiles.rlocation(path)).copySync(copy.path);
    }
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  String expected(String name) =>
      File('${fixture.path}/$name').readAsStringSync();

  T inFixture<T>(T Function() body) {
    final previous = Directory.current;
    Directory.current = fixture;
    try {
      return body();
    } finally {
      Directory.current = previous;
    }
  }

  for (final (params, listing) in [
    ('program.params', 'expected.txt'),
    ('code_names.params', 'code_names.expected.txt'),
  ]) {
    test('reads $params into what ships', () {
      final assets = inFixture(() => ProgramAssets.read(params));
      expect(_normalized(assets.describe()), expected(listing));
    });

    test('the list tool prints $params the same', () {
      final result = Process.runSync(list, [
        '--program-assets=$params',
      ], workingDirectory: fixture.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(_normalized('${result.stdout}'), expected(listing));
    });
  }

  test('holding both, it has each library by path', () {
    final assets = inFixture(() => ProgramAssets.read('program.params'));
    expect(assets.holdsData, isTrue);
    expect(assets.codeView, ProgramCodeView.libraries);
    final add = assets.code.firstWhere((a) => a.id == 'package:pick/add');
    expect((add.file, add.fileName), ('libadd.so', 'libadd.so'));
  });

  test('holding the code by name, it has no library paths and no data', () {
    final assets = inFixture(() => ProgramAssets.read('code_names.params'));
    expect(assets.holdsData, isFalse);
    expect(assets.codeView, ProgramCodeView.names);
    expect([for (final a in assets.code) a.file], everyElement(isNull));
    expect(
      [for (final a in assets.code) a.fileName],
      ['libadd.so', null, 'libtrim.so'],
    );
    expect(
      () => assets.data,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('`data = True`'),
        ),
      ),
    );
  });

  test('holding the data alone, it refuses to list code', () {
    final path = '${fixture.path}/data_only.params';
    File(path).writeAsStringSync(
      '--format\nrules_dart_program_assets/1\n--paths\nexec\n--holds\ndata\n'
      '--data-asset\npackage:a/x\nx\n',
    );
    final assets = ProgramAssets.read(path);
    expect([for (final a in assets.data) a.id], ['package:a/x']);
    expect(() => assets.code, throwsStateError);
  });

  group('refuses', () {
    String write(String name, String content) =>
        (File('${fixture.path}/$name')..writeAsStringSync(content)).path;
    String params(String body, {String holds = 'data code'}) =>
        '--format\nrules_dart_program_assets/1\n--paths\nexec\n'
        '--holds\n$holds\n$body';

    test('another format', () {
      final path = write('other.params', '--format\nsomething/2\n');
      expect(
        () => ProgramAssets.read(path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('is in the format `something/2`'),
          ),
        ),
      );
    });

    test('upstream encoded-asset JSON', () {
      final path = write('json.params', '{"assets": []}\n');
      expect(() => ProgramAssets.read(path), throwsFormatException);
    });

    test('a selection naming no candidate', () {
      final selection = write('bad.code_selection', 'package:pick/other\n');
      final path = write(
        'bad.params',
        params(
          '--link-code\npick\n$selection\n'
          '--candidate\npackage:pick/add\ndynamic_loading_bundle\nlibadd.so\n\n',
        ),
      );
      expect(
        () => ProgramAssets.read(path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('kept `package:pick/other`, which is not one of'),
          ),
        ),
      );
    });

    test('a selection with no candidates', () {
      final selection = write('empty.code_selection', '');
      final path = write(
        'unchosen.params',
        params('--link-code\npick\n$selection\n'),
      );
      expect(() => ProgramAssets.read(path), throwsFormatException);
    });

    test('a record of what the file does not hold', () {
      final path = write(
        'unheld.params',
        params(
          '--code-asset\npackage:a/c\ndynamic_loading_bundle\nlibc.so\n\n',
          holds: 'data',
        ),
      );
      expect(
        () => ProgramAssets.read(path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('a `--code-asset` record in a file that holds `data`'),
          ),
        ),
      );
    });

    test('a library path in a file holding code by name', () {
      final path = write(
        'pathed.params',
        params(
          '--code-asset\npackage:a/c\ndynamic_loading_bundle\nout/libc.so\n\n',
          holds: 'code-names',
        ),
      );
      expect(() => ProgramAssets.read(path), throwsFormatException);
    });

    for (final holds in ['', 'code code-names', 'data data', 'bytes']) {
      test('`--holds` `$holds`', () {
        final path = write('holds.params', params('', holds: holds));
        expect(() => ProgramAssets.read(path), throwsFormatException);
      });
    }

    test('an id twice', () {
      final path = write(
        'twice.params',
        params('--data-asset\npackage:a/x\nx\n--data-asset\npackage:a/x\ny\n'),
      );
      expect(() => ProgramAssets.read(path), throwsFormatException);
    });
  });
}
