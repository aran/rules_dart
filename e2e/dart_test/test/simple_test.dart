void main() {
  // Basic arithmetic
  assert(1 + 1 == 2, 'Expected 1 + 1 to equal 2');
  assert(2 * 3 == 6, 'Expected 2 * 3 to equal 6');
  assert(10 ~/ 3 == 3, 'Expected 10 ~/ 3 to equal 3');

  // String operations
  assert('hello'.toUpperCase() == 'HELLO');
  assert('Hello World'.contains('World'));
  assert('dart'.length == 4);

  print('All simple tests passed!');
}
