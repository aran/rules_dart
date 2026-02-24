import 'package:lib/greeter.dart';

void main() {
  final greeter = Greeter('Test');
  assert(greeter.greet() == 'Hello, Test!');
  print('All tests passed!');
}
