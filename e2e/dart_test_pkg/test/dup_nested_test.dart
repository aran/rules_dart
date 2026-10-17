import 'package:dart_test_pkg/dup/shared.dart';
import 'package:dart_test_pkg/dup/top.dart';
import 'package:test/test.dart';

void main() {
  test('a library listed by a dependency and its dependent', () {
    expect(topValue(), 43);
    expect(Shared().value, 42);
  });
}
