import 'package:greeter/greeter.dart';
import 'version.dart';

void main() {
  print('library_deps v$version');
  print(greet('world'));
  print(greet('dart'));
}
