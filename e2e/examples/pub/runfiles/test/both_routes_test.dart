import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:runfiles_user/data_path.dart';
import 'package:test/test.dart';

void main() {
  test('both routes to package:runfiles are one library', () {
    const file = '_main/pub/runfiles/lib/data_path.dart';
    expect(dataPath(file), Runfiles.create().rlocation(file));
    expect(File(dataPath(file)).existsSync(), isTrue);
  });
}
