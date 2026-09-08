import 'package:colocated_fixture/consumer.dart';
import 'package:test/test.dart';

/// The test lives in the same Bazel package as the library it tests, which is
/// the ordinary pub layout.
void main() {
  test('pure-source package resolves beside its own test', () {
    expect(consume(), 'generated lib works');
  });
}
