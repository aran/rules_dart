import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Asserts the compiled JS actually carries the behavior the rule promises:
/// the space-containing define survived intact, the root package's (empty
/// package_root) sources were staged, and the external pub package resolved.
/// The `.js.map` the script points at is an output, also reachable alone
/// through the `source_map` output group, and names no absolute path.
void main(List<String> args) {
  final r = Runfiles.create();
  final js = File(r.rlocation('_main/web/app/app.js')).readAsStringSync();

  void expectContains(String needle, String why) {
    if (!js.contains(needle)) {
      throw StateError('app.js missing "$needle" ($why)');
    }
  }

  expectContains('hello world', 'defines with spaces must survive unsplit');
  expectContains(
    'hello from the root package',
    'empty-package_root dep package must be staged',
  );
  expectContains('flag count:', 'external pub package code must compile in');

  if (!js.contains('sourceMappingURL=app.js.map')) {
    throw StateError('app.js does not point at app.js.map');
  }
  final mapFile = File(r.rlocation('_main/web/app/app.js.map'));
  if (!mapFile.existsSync()) {
    throw StateError('app.js.map is not an output of app');
  }
  if (args.single != '_main/web/app/app.js.map') {
    throw StateError('source_map output group gave ${args.single}');
  }
  final map = mapFile.readAsStringSync();
  if (map.contains('/Users/') ||
      map.contains('sandbox') ||
      map.contains('file:')) {
    throw StateError('app.js.map names an absolute path');
  }
  stdout.writeln('PASS');
}
