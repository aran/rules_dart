import 'package:reexport_fixture/api.dart';
import 'package:test/test.dart';

/// Consumes a generated symbol reached through a `dart_library` that
/// re-exports the generated file.
void main() {
  test('generated symbol reachable through a re-export', () {
    expect(generatedValue(), 'generated lib works');
  });
}
