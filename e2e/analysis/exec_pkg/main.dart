// The entrypoint, outside the package's `lib/`: nothing can reach it by
// `package:` URI, and it reaches the package's own sources only because the
// constructor put that package's record in the closure.
import 'dart:io';

import 'package:analysis_exec/report.dart';

void main() {
  stdout.writeln(report(['world']));
}
