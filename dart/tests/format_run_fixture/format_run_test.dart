import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

// Formatted for a 100-column page with trailing commas preserved: at stock
// defaults the long call wraps and `g(1,)` collapses onto one line.
const _formatted = '''
void f(int Function(int, int, int) someFunction) {
  final result = someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree);
  g(
    1,
  );
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

  test('formats with the included and the local formatter settings', () {
    final file = File('${workspace.path}/lib/a.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        _formatted.replaceFirst('void h() {}', 'void  h( ){}'),
      );

    final result = Process.runSync(
      format,
      ['lib'],
      environment: {
        'BUILD_WORKING_DIRECTORY': workspace.path,
        'DART_FORMAT_CONFIG': config,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, isNot(contains('Warning')));
    expect(
      result.stdout,
      contains('Formatted lib${Platform.pathSeparator}a.dart'),
    );
    expect(file.readAsStringSync(), _formatted);
  });
}
