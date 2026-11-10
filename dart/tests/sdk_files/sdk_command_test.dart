/// Runs an SDK command through `@rules_dart//dart` from a test's `data`, as
/// README tells a test that runs SDK commands itself to.
///
/// The argument is the runfiles path of `@rules_dart//dart`.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final dart = Runfiles.create().rlocation(args.single);
  final work = Directory.systemTemp.createTempSync('sdk_command.');
  try {
    final source = File('${work.path}/main.dart')
      ..writeAsStringSync("void main() => print('compiled');\n");
    final kernel = '${work.path}/main.dill';
    final compile = Process.runSync(dart, [
      'compile',
      'kernel',
      '-o',
      kernel,
      source.path,
    ]);
    if (compile.exitCode != 0 || !File(kernel).existsSync()) {
      stderr.writeln('dart compile kernel failed (${compile.exitCode}):');
      stderr.writeln('${compile.stdout}${compile.stderr}');
      exit(1);
    }
  } finally {
    work.deleteSync(recursive: true);
  }
}
