import 'package:test/test.dart';

void main() {
  group('basic arithmetic', () {
    test('addition', () {
      expect(1 + 1, equals(2));
    });

    test('multiplication', () {
      expect(3 * 4, equals(12));
    });
  });
}
