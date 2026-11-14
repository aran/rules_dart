import 'package:test/test.dart';

import '../bin/shared_loaded.dart';

void main() {
  test('loads the one file of the filegroup it uses', () {
    expect(sharedLoaded, isTrue);
  });
}
