import 'package:mylib/mylib.dart' as mylib;

/// Adds two integers.
int add(int a, int b) => a + b;

/// Greets someone by name.
String greet(String name) => 'Hello, $name!';

/// Generates a range of integers from [start] to [end] (exclusive).
List<int> range(int start, int end) {
  return List.generate(end - start, (i) => start + i);
}

// Cross-package resolution: the analyzer must resolve package: imports of
// dep libraries from the staged project.

/// Uses a dep-package symbol so the import is not unused.
int addViaDep(int a, int b) => mylib.add(a, b);
