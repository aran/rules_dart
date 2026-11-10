import 'package:web_compiler_fixture/facade.dart';

void main() {
  // No `dart:io`: this entrypoint also compiles for JavaScript and Wasm.
  // ignore: avoid_print
  print(whichVariant());
}
