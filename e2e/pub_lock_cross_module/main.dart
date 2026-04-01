import 'package:module_b/greeter.dart';
import 'package:collection/collection.dart';

void main() {
  // Uses module_b's greeter (which internally uses package:path)
  print(greet('world'));

  // Uses collection from root module's pub deps
  final numbers = [3, 1, 4, 1, 5];
  final first = numbers.firstWhereOrNull((n) => n > 4);
  print('First > 4: $first');

  print('Cross-module test passed!');
}
