import 'dart:io';

import 'package:glyphs/glyphs.dart';

const _favourite = Glyph('star');

void main() {
  stdout
    ..writeln(_favourite)
    ..writeln(const Glyph('heart'));
}
