import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Each web binary compiled its own compiler's variant, and only that one.
void main() {
  final r = Runfiles.create();
  final js = File(r.rlocation('_main/web/per_compiler/app_js.js'))
      .readAsStringSync();
  final wasm = String.fromCharCodes(
    File(r.rlocation('_main/web/per_compiler/app_wasm.wasm')).readAsBytesSync(),
  );

  void expect(bool ok, String what) {
    if (!ok) throw StateError(what);
  }

  expect(js.contains('i64 variant js'), 'app_js.js lacks the js variant');
  expect(!js.contains('i64 variant typed'), 'app_js.js has the typed variant');
  expect(
    wasm.contains('i64 variant typed'),
    'app_wasm.wasm lacks the typed variant',
  );
  expect(!wasm.contains('i64 variant js'), 'app_wasm.wasm has the js variant');
  stdout.writeln('PASS');
}
