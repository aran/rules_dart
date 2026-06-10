import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Asserts the compiled JS actually carries the behavior the rule promises:
/// the space-containing define survived intact, the root package's (empty
/// lib_root) sources were staged, and the external pub package resolved.
void main() {
  final r = Runfiles.create();
  final js = File(r.rlocation('_main/app.js')).readAsStringSync();

  void expectContains(String needle, String why) {
    if (!js.contains(needle)) {
      throw StateError('app.js missing "$needle" ($why)');
    }
  }

  expectContains('hello world', 'defines with spaces must survive unsplit');
  expectContains(
    'hello from the root package',
    'empty-lib_root dep package must be staged',
  );
  expectContains('flag count:', 'external pub package code must compile in');
  print('PASS');
}
