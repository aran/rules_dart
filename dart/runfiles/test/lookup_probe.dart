import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Driven by runfiles_test: builds a [Runfiles] with `Runfiles.create()` from
/// whatever RUNFILES_* environment the test gave it, then prints one line per
/// argument, JSON-encoded because a path may hold a newline: the path `rlocation` returns, or `ERROR` when it throws.
/// Exit code 3 means `create()` itself failed.
void main(List<String> args) {
  final Runfiles runfiles;
  try {
    runfiles = Runfiles.create();
  } on StateError catch (e) {
    stderr.writeln('create failed: $e');
    exit(3);
  }
  for (final arg in args) {
    try {
      stdout.writeln(jsonEncode(runfiles.rlocation(arg)));
    } catch (_) {
      stdout.writeln(jsonEncode('ERROR'));
    }
  }
}
