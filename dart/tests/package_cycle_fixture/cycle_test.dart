import 'dart:io';

import 'package:ping/ping.dart';
import 'package:pong/pong.dart';

void main() {
  if (ping(3) != 3 || pong(2) != 2) {
    stderr.writeln('ping(3) is ${ping(3)}, pong(2) is ${pong(2)}');
    exit(1);
  }
}
