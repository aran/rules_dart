// Checks which symbols the library a program ships for a code asset exports.
//
// Arguments: the runfiles paths of a `dart_program_assets` target's files,
// separated by spaces (its manifest, `<name>.assets.json`, among them), the
// code asset's id, then `+<symbol>` for each symbol the library must export
// and `-<symbol>` for each it must not.
import 'dart:convert';
import 'dart:ffi';
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
  final encoding = (manifest['assets']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((asset) => asset['encoding']! as Map<String, Object?>)
      .singleWhere((encoding) => encoding['id'] == args[1]);
  var path = (encoding['file']! as String).split('/');
  if (path.first == 'bazel-out') path = path.sublist(3);
  final library = DynamicLibrary.open(
    runfiles.rlocation('_main/${path.join('/')}'),
  );
  final wrong = [
    for (final expectation in args.skip(2))
      if (library.providesSymbol(expectation.substring(1)) !=
          expectation.startsWith('+'))
        expectation,
  ];
  if (wrong.isNotEmpty) {
    stdout.writeln('FAIL: ${args[1]} does not meet $wrong');
    exit(1);
  }
}
