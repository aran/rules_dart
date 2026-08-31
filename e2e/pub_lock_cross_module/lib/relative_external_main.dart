import 'dart:io';

import '../module_b+/lib/greeter.dart';
import '../generated_entrypoint_src.dart';

void main() {
  stdout.writeln(greet('$generatedEntrypointValue relative import'));
}
