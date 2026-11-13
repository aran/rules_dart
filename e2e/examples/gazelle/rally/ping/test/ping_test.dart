// Two packages that import each other, which Gazelle builds as one cycle.
import 'dart:io';

import 'package:ping/ping.dart';
import 'package:pong/pong.dart';

void main() {
  if (ping(4) != 4 || pong(3) != 3) {
    stderr.writeln('ping(4) is ${ping(4)}, pong(3) is ${pong(3)}');
    exit(1);
  }
}
