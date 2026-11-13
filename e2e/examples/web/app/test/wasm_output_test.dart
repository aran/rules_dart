import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Asserts `dart_wasm_binary` keeps everything needed to run the module: the
/// `.mjs` loader (also reachable alone through the `mjs` output group), the
/// `.support.js` feature check, and the source map.
void main(List<String> args) {
  final r = Runfiles.create();

  File output(String path) {
    final file = File(r.rlocation(path));
    if (!file.existsSync()) {
      throw StateError('$path is not an output of app_wasm');
    }
    return file;
  }

  output('_main/web/app/app_wasm.wasm');
  output('_main/web/app/app_wasm.support.js');
  final map = output('_main/web/app/app_wasm.wasm.map').readAsStringSync();
  // An absolute or sandbox path in the map would carry the builder's user name
  // and differ per machine and per sandbox.
  final sources = (jsonDecode(map) as Map<String, Object?>)['sources']! as List;
  for (final source in sources.cast<String>()) {
    if (source.startsWith('file:') ||
        source.startsWith('/') ||
        source.contains('sandbox') ||
        source.contains('/Users/') ||
        source.contains('/home/')) {
      throw StateError('app_wasm.wasm.map names an absolute path: $source');
    }
  }

  // Every source resolves, relative to the map as a browser would, to a real
  // file, and the map reads as dart2js's does. The map is
  // `bazel-out/<config>/bin/web/app/app_wasm.wasm.map`, so a source that
  // climbs five levels is in the execroot (`external/<repo>/...` or a package
  // of this workspace), and one that does not is below the output directory,
  // where `app_wasm.proj/src/` holds the staged copy of the workspace's root.
  var resolved = 0;
  for (final source in sources.cast<String>()) {
    if (source.startsWith('org-dartlang-sdk:')) continue;
    String runfile;
    if (source.startsWith('../../../../../external/')) {
      runfile = source.substring('../../../../../external/'.length);
    } else if (source.startsWith('../../../../../')) {
      runfile = '_main/${source.substring('../../../../../'.length)}';
    } else if (source.startsWith('app_wasm.proj/src/')) {
      runfile = '_main/${source.substring('app_wasm.proj/src/'.length)}';
    } else {
      throw StateError('app_wasm.wasm.map names $source, not relative to it');
    }
    if (!File(r.rlocation(runfile)).existsSync()) {
      throw StateError(
        'app_wasm.wasm.map names $source, which is not $runfile',
      );
    }
    resolved++;
  }
  if (resolved < 3) {
    throw StateError('only $resolved of the sources of the map are checked');
  }
  final mjs = output('_main/web/app/app_wasm.mjs').readAsStringSync();
  if (!mjs.contains('instantiate')) {
    throw StateError('app_wasm.mjs is not the module loader');
  }
  if (args.single != '_main/web/app/app_wasm.mjs') {
    throw StateError('mjs output group gave ${args.single}');
  }
  stdout.writeln('PASS');
}
