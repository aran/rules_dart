import 'package:source_set_fixture/message.dart';
import 'package:test/test.dart';

/// The `dart_test` consumer: a package assembled by `copy_to_directory` and
/// reached through `dart_library`'s `srcs_dir`.
void main() {
  test('generated part is reachable through copy_to_directory + srcs_dir', () {
    expect(message(), 'generated part works');
  });
}
