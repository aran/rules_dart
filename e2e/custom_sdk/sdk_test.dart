import 'dart:io';

import 'package:greeting/greeting.dart';
import 'package:runfiles/runfiles.dart';

/// The SDK in use is 3.14.0 rather than the release rules_dart pins, this
/// program runs on it, and so does one it compiled ahead of time.
///
/// `DART` and `GREET` are the runfiles paths of the SDK's `dart` launcher and
/// of the compiled program.
void main() {
  final runfiles = Runfiles.create();
  if (!Platform.version.startsWith('3.14.0 ')) {
    stderr.writeln('This test runs on Dart ${Platform.version}');
    exit(1);
  }
  String path(String variable) =>
      runfiles.rlocation(Platform.environment[variable]!);
  final version = Process.runSync(path('DART'), ['--version']);
  if (!'${version.stdout}'.contains('Dart SDK version: 3.14.0 ')) {
    stderr.writeln('`dart --version` said: ${version.stdout}${version.stderr}');
    exit(1);
  }
  final greet = Process.runSync(path('GREET'), const []);
  if ('${greet.stdout}'.trim() != greeting) {
    stderr.writeln('The program said: ${greet.stdout}${greet.stderr}');
    exit(1);
  }
}
