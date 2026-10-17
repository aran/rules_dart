import 'package:dart_test_pkg/sib/b.dart';
import 'package:dart_test_pkg/sib/common.dart';
import 'package:test/test.dart';

// Run 2.
void main() {
  test('a library listed by two unrelated targets', () {
    expect(bValue(), 8);
    expect(Common().value, 7);
    expect(Common().next, 7);
  });
}
