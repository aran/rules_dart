import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Checks the `dart_source_set` whose source is another source set. Its
/// directory must hold the inner set's files under `inner/`, and its own file.
void main(List<String> args) {
  final dir = Directory(Runfiles.create().rlocation(args[0]));

  test('a tree-artifact source is copied file by file under its own path', () {
    final files = <String, String>{
      for (final f in dir.listSync(recursive: true).whereType<File>())
        f.path.substring(dir.path.length + 1).replaceAll('\\', '/'): f
            .readAsStringSync(),
    };
    expect(files.keys, unorderedEquals(['inner/lib/a.dart', 'lib/c.dart']));
    expect(files['inner/lib/a.dart'], contains("const a = 'a';"));
    expect(files['lib/c.dart'], contains("const c = 'c';"));
  });
}
