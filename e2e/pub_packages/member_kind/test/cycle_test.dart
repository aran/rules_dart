import 'dart:io';

import 'package:alpha/alpha.dart';

void main() {
  final got = alphaThroughBeta();
  if (got != 'beta sees alpha and gamma') {
    stderr.writeln('unexpected: $got');
    exit(1);
  }
}
