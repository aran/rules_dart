// Checks the data assets a program ships, as its manifest lists them.
//
// Arguments: the runfiles paths of a `dart_program_assets` target's files,
// separated by spaces (its manifest, `<name>.assets.json`, among them), then
// the `<id>=<content>` each data asset must hold, one argument each. The
// manifest must list exactly those, and each file must hold its content.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final manifestPath = args.first
      .split(' ')
      .singleWhere((path) => path.endsWith('.assets.json'));
  final manifest = jsonDecode(
    File(runfiles.rlocation(manifestPath)).readAsStringSync(),
  ) as Map<String, Object?>;
  final shipped = <String, String>{};
  for (final asset
      in (manifest['assets']! as List<Object?>).cast<Map<String, Object?>>()) {
    if (asset['type'] != 'data_assets/data') continue;
    final encoding = asset['encoding']! as Map<String, Object?>;
    final id = 'package:${encoding['package']}/${encoding['name']}';
    final file = runfiles.rlocation(_runfilesPath(encoding['file']! as String));
    shipped[id] = File(file).readAsStringSync().trim();
  }
  final expected = {
    for (final pair in args.skip(1).map((a) => a.split('=')))
      pair.first: pair.last,
  };
  final ok =
      shipped.length == expected.length &&
      expected.entries.every((e) => shipped[e.key] == e.value);
  if (!ok) {
    stdout.writeln('FAIL: shipped $shipped, expected $expected');
    exit(1);
  }
}

/// The runfiles path of a file the manifest names by its path from the
/// execution root: an output's under `bazel-out/<configuration>/bin/`, and a
/// file of another repository's under `external/<repository>/`.
String _runfilesPath(String path) {
  var segments = path.split('/');
  if (segments.first == 'bazel-out') segments = segments.sublist(3);
  if (segments.first == 'external') return segments.skip(1).join('/');
  return '_main/${segments.join('/')}';
}
