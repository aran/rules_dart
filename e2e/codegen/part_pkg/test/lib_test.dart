import 'package:part_pkg_fixture/message.dart';
import 'package:test/test.dart';

/// The `dart_test` consumer: a generated `part` reached through a `dart_library`.
void main() {
  test('generated part is reachable from a dart_test', () {
    expect(message(), 'generated part works');
  });
}
