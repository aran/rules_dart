import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Prints a line from code in its own kernel and from a dependency's, so a
/// program missing either fails to load or to print.
void main() {
  stdout.writeln(
    'kernel_list_fixture ran with ${Runfiles.fromState().runtimeType}',
  );
}
