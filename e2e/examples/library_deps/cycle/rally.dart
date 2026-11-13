import 'dart:io';

import 'package:ping/ping.dart';
import 'package:pong/pong.dart';

void main() {
  stdout.writeln('${shout('rally')}: ping ${ping(4)}, pong ${pong(3)}');
}
