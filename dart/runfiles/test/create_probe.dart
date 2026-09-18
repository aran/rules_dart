import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Driven by runfiles_test: builds a [Runfiles] by probing from its own
/// executable path, says `ready`, waits for stdin to close, then prints the
/// contents of the `_main/data.txt` runfile. The pause lets the test move
/// things between `create()` and `rlocation`.
Future<void> main() async {
  final runfiles = Runfiles.create();
  stdout.writeln('ready');
  await stdout.flush();
  await stdin.drain<void>();
  stdout.writeln(File(runfiles.rlocation('_main/data.txt')).readAsStringSync());
}
