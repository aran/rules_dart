import 'package:web_compiler_e2e/vec.dart';

/// A VM program, which no web compiler builds, gets the `none` branch.
void main() {
  final described = describe();
  if (!described.contains('i64 variant typed')) {
    throw StateError('expected the typed variant on the VM, got: $described');
  }
}
