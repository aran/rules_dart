import 'dart:io';

import 'package:sounds/sounds.dart';

void main() {
  stdout
    ..writeln('package:jingle/tune.txt')
    ..writeln(const Sound('chime').assetId);
}
