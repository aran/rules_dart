import 'package:source_set_fixture/message.dart';
import 'package:test/test.dart';

/// The `dart_test` consumer: a package assembled by `dart_source_set` and
/// reached through `dart_library`'s `srcs_dir`.
void main() {
  test('generated part is reachable through dart_source_set + srcs_dir', () {
    expect(message(), 'generated part works');
  });
}
