import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('data is found by workspace-relative path', () {
    expect(
      File('dart/tests/test_cwd_fixture/data.txt').readAsStringSync().trim(),
      'present',
    );
  });
}
