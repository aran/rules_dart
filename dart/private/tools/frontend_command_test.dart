/// Runs `kernel_tool frontend` over the SDK's real `frontend_server`, which is
/// the compile every executable's kernel step is: what a user sees in the
/// build log is what it prints, so a compile that succeeds must print nothing
/// and one that fails must print the compiler's message.
///
/// Arguments: the runfiles paths of `kernel_tool` and of the SDK's `kernel`
/// file set copy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final kernelTool = runfiles.rlocation(args[0]);
  final sdk = runfiles.rlocation(args[1]);
  final exe = Platform.isWindows ? '.exe' : '';
  final runtime = '$sdk/bin/dartaotruntime$exe';

  late Directory work;

  setUpAll(() {
    work = Directory.systemTemp.createTempSync('frontend_command.');
    File('${work.path}/good.dart')
        .writeAsStringSync("void main() => print('hello');\n");
    File('${work.path}/bad.dart')
        .writeAsStringSync("void main() { int x = 'not an int'; }\n");
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  // The server's own command line, as `dart_kernel_action` builds it.
  List<String> compiler(String main, String output) => [
    '$sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    '--sdk-root',
    '$sdk/lib/_internal/',
    '--platform',
    'vm_platform_product.dill',
    '--no-print-incremental-dependencies',
    '--output-dill',
    output,
    main,
  ];

  Future<ProcessResult> run(String executable, List<String> arguments) =>
      Process.run(
        executable,
        arguments,
        workingDirectory: work.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: {
          'HOME': work.path,
          'APPDATA': work.path,
          'DART_SUPPRESS_ANALYTICS': 'true',
        },
      );

  Future<ProcessResult> frontend(String main, String output) => run(
    kernelTool,
    ['frontend', '--runtime', runtime, '--', ...compiler(main, output)],
  );

  test(
    'the server prints its protocol on success, the noise to keep out',
    () async {
      final result = await run(runtime, compiler('good.dart', 'direct.dill'));
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, startsWith('result '));
    },
  );

  test('a compile that succeeds prints nothing', () async {
    final result = await frontend('good.dart', 'good.dill');
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, isEmpty);
    expect(result.stderr, isEmpty);
    expect(File('${work.path}/good.dill').existsSync(), isTrue);
  });

  test('a compile that fails shows the compiler\'s error and fails', () async {
    final result = await frontend('bad.dart', 'bad.dill');
    expect(result.exitCode, isNot(0));
    expect(result.stdout, isEmpty);
    expect(
      result.stderr,
      allOf(
        contains('bad.dart:1:'),
        contains('Error:'),
        contains("A value of type 'String' can't be assigned"),
        isNot(contains('result ')),
      ),
    );
  });

  test('a compile that cannot start reports it', () async {
    final result = await run(kernelTool, [
      'frontend',
      '--runtime',
      runtime,
      '--',
      '$sdk/no/such/snapshot',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, isEmpty);
    expect(result.stderr, isNotEmpty);
  });
}
