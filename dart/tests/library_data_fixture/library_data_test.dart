// A library's `data` reaches the runfiles of a test that depends on it only
// through another library, with the runfiles of a `data` target alongside.
import 'dart:io';

import 'package:library_data_fixture/reader.dart';
import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  for (final (path, text) in [
    (fixturePath, 'library data'),
    ('dart/tests/library_data_fixture/helper_data.txt', 'helper data'),
  ]) {
    final file = File(runfiles.rlocation('_main/$path'));
    if (!file.existsSync() || file.readAsStringSync().trim() != text) {
      throw StateError('$path is not in runfiles as ${file.path}');
    }
  }
}
