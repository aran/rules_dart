// Puts the files `dart compile wasm` wrote into a directory where the rule
// declares them, rewriting the source map's sources on the way: each is made
// relative to the map's own location, as dart2js writes them.
//
// dart2wasm writes each source's URI whole, and the compile names the
// execroot's sources `execroot:///<execroot-relative path>` (a `file:` URI
// would hold the sandbox's absolute path). A browser resolves a map's sources
// against the map's URL, so a source that resolves in the tree the map is
// served from has to be relative to the map: `app_wasm.proj/src/main.dart` for
// a map in the same directory, `../../../external/pkg/lib/a.dart` for a
// package outside it. Other URIs (`org-dartlang-sdk:`) are left as they are.
//
// The compiler names its map after the module and the module names its loader,
// so the compile cannot write them to the declared paths itself.
//
// Run as `dart wasm_outputs.dart <dir> <name> <wasm> <mjs> <support.js> <map>`
// from the execroot: `<dir>/<name>.{wasm,mjs,support.js,wasm.map}` are what the
// compiler wrote; the last four paths are where they go, relative to the
// execroot (the map's says where it will be).

import 'dart:convert';
import 'dart:io';

const _scheme = 'execroot:///';

/// [source] relative to the directory of [mapPath], if [source] is an
/// `execroot:///` URI; otherwise [source].
String relativizeSource(String source, String mapPath) {
  if (!source.startsWith(_scheme)) return source;
  final target = _segments(source.substring(_scheme.length));
  final from = _segments(mapPath)..removeLast();
  var common = 0;
  while (common < from.length &&
      common < target.length - 1 &&
      from[common] == target[common]) {
    common++;
  }
  return [
    for (var i = common; i < from.length; i++) '..',
    ...target.skip(common),
  ].join('/');
}

List<String> _segments(String path) =>
    path.split('/').where((s) => s.isNotEmpty && s != '.').toList();

/// [mapJson] with its `sources` made relative to [mapPath]'s directory.
String relativizeMap(String mapJson, String mapPath) {
  final map = jsonDecode(mapJson) as Map<String, Object?>;
  map['sources'] = [
    for (final s in map['sources']! as List)
      relativizeSource(s as String, mapPath),
  ];
  return jsonEncode(map);
}

void main(List<String> args) {
  if (args.length != 6) {
    stderr.writeln(
      'usage: wasm_outputs <dir> <name> <wasm> <mjs> <support.js> <map>',
    );
    exit(2);
  }
  final dir = args[0];
  final name = args[1];
  File('$dir/$name.wasm').copySync(args[2]);
  File('$dir/$name.mjs').copySync(args[3]);
  File('$dir/$name.support.js').copySync(args[4]);
  File(args[5]).writeAsStringSync(
    relativizeMap(File('$dir/$name.wasm.map').readAsStringSync(), args[5]),
  );
}
