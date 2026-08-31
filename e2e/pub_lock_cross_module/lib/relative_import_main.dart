import 'dart:io';

import '../generated_entrypoint_src.dart';
import '../support/lib/greeting.dart';

void main() {
  stdout.writeln(greet('$generatedEntrypointValue relative import'));
}
