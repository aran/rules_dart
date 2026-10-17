import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final mapPath = Runfiles.create().rlocation(args.single);
  final raw = File(mapPath).readAsStringSync();
  if (raw.contains('file:')) {
    throw StateError('wasm source map contains file: URI:\n$raw');
  }

  final decoded = jsonDecode(raw) as Map<String, Object?>;
  final sources = (decoded['sources'] as List).cast<String>();
  if (sources.isEmpty) {
    throw StateError('expected non-empty sources in wasm source map');
  }

  var sawMain = false;
  for (final src in sources) {
    if (src.startsWith('/') || src.startsWith('file:')) {
      throw StateError('source map entry is an absolute path: $src');
    }
    if (src.startsWith('org-dartlang-bazel:///') &&
        src.endsWith('/dart/tests/pc_fixture/bin/main.dart')) {
      sawMain = true;
    }
  }
  if (!sawMain) {
    throw StateError(
      'expected org-dartlang-bazel:/// entry for bin/main.dart in $sources',
    );
  }
}
