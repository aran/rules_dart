import 'dart:io';

import 'package:ping/ping.dart';

void main() {
  final said = ping(3);
  if (said != 'ping pong ping pong') {
    stderr.writeln('ping(3) said "$said"');
    exit(1);
  }
}
