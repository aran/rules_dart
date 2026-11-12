import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

void main() {
  // Writes through `stdout` rather than `print` because the lint set bans the
  // latter. Both hub packages have to stay genuinely evaluated here: they are
  // the only evidence that each hub contributed a linked package, which is
  // what the dedup this workspace tests depends on.
  stdout
    ..writeln('Path joined: ${p.join('usr', 'local', 'bin')}')
    ..writeln('First even: ${[1, 2, 3].firstWhereOrNull((n) => n.isEven)}')
    ..writeln('Multi-lock dedup test passed!');
}
