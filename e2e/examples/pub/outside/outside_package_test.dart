// A `path` package outside the repository is built from its directory, however
// the lock names it.
import 'package:outside_greeting/outside_greeting.dart';

void main() {
  final got = outsideGreeting();
  if (got != 'hello from outside the repository') {
    throw StateError('outsideGreeting(): got "$got"');
  }
}
