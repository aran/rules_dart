import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Both web compilers compiled the program, the generated code included.
void main() {
  final r = Runfiles.create();
  final js = File(r.rlocation('_main/fixtures/no_pubspec/app/web_js.js'))
      .readAsStringSync();
  final wasm = String.fromCharCodes(
    File(r.rlocation('_main/fixtures/no_pubspec/app/web_wasm.wasm'))
        .readAsBytesSync(),
  );
  for (final (what, text) in [('js', js), ('wasm', wasm)]) {
    if (!text.contains('visits')) {
      throw StateError('the $what output lacks the generated toJson');
    }
  }
}
