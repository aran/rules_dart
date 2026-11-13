import 'dart:io';

void main() {
  // Basic arithmetic
  assert(1 + 1 == 2, 'Expected 1 + 1 to equal 2');
  assert(2 * 3 == 6, 'Expected 2 * 3 to equal 6');
  assert(10 ~/ 3 == 3, 'Expected 10 ~/ 3 to equal 3');

  // String operations
  assert('hello'.toUpperCase() == 'HELLO', "Expected 'hello' to upcase");
  assert('Hello World'.contains('World'), "Expected 'World' to be contained");
  assert('dart'.length == 4, "Expected 'dart' to be 4 characters");

  stdout.writeln('All simple tests passed!');
}
