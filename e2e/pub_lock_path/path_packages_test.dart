// A path package built from its pubspec is the package in its directory.
import 'package:local_greeting/local_greeting.dart';

void main() {
  final got = greeting();
  if (got != 'hello from a path package') {
    throw StateError('greeting(): got "$got"');
  }
}
