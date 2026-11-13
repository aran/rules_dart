import 'dart:io';

import 'package:ping/ping.dart';
import 'package:pong/pong.dart';

void main() {
  if (ping(4) != 4 || pong(3) != 3 || shout('ping') != 'Ping') {
    stderr.writeln('ping(4) ${ping(4)}, pong(3) ${pong(3)}');
    exit(1);
  }
}
