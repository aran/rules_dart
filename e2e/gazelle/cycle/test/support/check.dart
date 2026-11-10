import 'package:cycle/src/d/d.dart';
import 'package:cycle/src/e/e.dart';

/// What is wrong with the package's results, if anything.
List<String> problems(String greeting) => [
  if (greeting != 'hello you') 'greet: $greeting',
  if ('${down(2)}' != '[1, 0]') 'down: ${down(2)}',
  if (twice(2) != 4) 'twice: ${twice(2)}',
];
