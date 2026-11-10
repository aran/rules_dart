/// Runs each `dart_binary` of the fixture, one per compile mode, and checks
/// that it saw its define values whole.
///
/// The front end `gen_kernel` splits a `-D` value on commas, so `hello,world`
/// reached the program as `hello`. Every argument is `name=rlocationpath`.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  var failures = 0;
  for (final arg in args) {
    final i = arg.indexOf('=');
    final name = arg.substring(0, i);
    final result = Process.runSync(
      runfiles.rlocation(arg.substring(i + 1)),
      [],
    );
    final out = '${result.stdout}'.trim();
    if (result.exitCode == 0 && out == 'hello,world;1,2') {
      stdout.writeln('ok: $name');
    } else {
      failures++;
      stderr.writeln(
        'FAIL: $name: exit ${result.exitCode}, stdout "$out", '
        'stderr "${result.stderr}"',
      );
    }
  }
  exit(failures == 0 ? 0 : 1);
}
