import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `kernel_outline` takes its arguments from a `@paramsfile`: a package with
/// many dependencies names more kernel files than a Windows command line holds.
///
/// The argument is the runfiles path of `kernel_outline`.
void main(List<String> args) {
  final tool = Runfiles.create().rlocation(args[0]);

  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('kernel_outline'));
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> lines) {
    final params = File('${scratch.path}/params')
      ..writeAsStringSync(lines.map((line) => '$line\n').join());
    return Process.run(tool, ['@${params.path}']);
  }

  test('reads its arguments from a params file', () async {
    final missing = '${scratch.path}/missing.dill';
    final result = await run(['--load', missing]);
    expect(result.exitCode, isNot(0));
    expect('${result.stdout}${result.stderr}', contains('missing.dill'));
  });

  test('does nothing, successfully, for an empty params file', () async {
    final result = await run([]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('still refuses an unknown argument in a params file', () async {
    final result = await run(['--bogus', 'x']);
    expect(result.exitCode, 2);
  });
}
