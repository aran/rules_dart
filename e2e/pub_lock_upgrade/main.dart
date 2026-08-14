import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

// The two interpolated expressions are the only use of each hub, so they have
// to stay live for this fixture to prove both resolve. `stdout` rather than
// `print` because very_good_analysis bans the latter.
void main() {
  stdout
    ..writeln('Path joined: ${p.join('usr', 'local', 'bin')}')
    ..writeln('First even: ${[1, 2, 3].firstWhereOrNull((n) => n.isEven)}')
    ..writeln('Multi-lock dedup test passed!');
}
