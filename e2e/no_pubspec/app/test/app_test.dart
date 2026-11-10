import 'package:app/app.dart';

/// The message, through the generated JSON code and the other package.
void main() {
  const expected = 'Hello, Bazel! {"name":"Bazel","visits":3}';
  final actual = message();
  if (actual != expected) {
    throw StateError('message() is "$actual", not "$expected"');
  }
}
