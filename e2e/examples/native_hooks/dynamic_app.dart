import 'dart:io';

import 'package:glyphs/glyphs.dart';

void main(List<String> args) {
  // A name only known at run time: the link hook must refuse this.
  stdout.writeln(Glyph(args.isEmpty ? 'star' : args.first));
}
