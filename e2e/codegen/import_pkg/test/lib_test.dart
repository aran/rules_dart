import 'package:import_fixture/via_package.dart';
import 'package:import_fixture/via_relative.dart';
import 'package:test/test.dart';

/// The `dart_test` consumer for generated standalone libraries reached via both
/// a `package:` import and a relative import.
void main() {
  test('generated lib reachable via package: import', () {
    expect(viaPackage(), 'generated lib works');
  });
  test('generated lib reachable via relative import', () {
    expect(viaRelative(), 'generated lib works');
  });
}
