import 'package:mylib/mylib.dart' as mylib;

/// Greets someone by name.
String greet(String name) => 'Hello, $name!';

/// Adds two integers via the dependency package.
int addViaDep(int a, int b) => mylib.add(a, b);
