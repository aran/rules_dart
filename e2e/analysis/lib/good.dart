/// Adds two integers.
int add(int a, int b) => a + b;

/// Greets someone by name.
String greet(String name) => 'Hello, $name!';

/// Generates a range of integers from [start] to [end] (exclusive).
List<int> range(int start, int end) {
  return List.generate(end - start, (i) => start + i);
}
