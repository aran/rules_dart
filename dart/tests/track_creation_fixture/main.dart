// Fails unless every construction of a tracked class, in this file and in a
// library it imports, records where it happened exactly when `TRACKED` says so.
import 'dart:developer';

import 'package:track_creation_maker/maker.dart';
import 'package:track_creation_marked/marked.dart';

void main() {
  const tracked = bool.fromEnvironment('TRACKED');
  final here = CreationLocation.of(Marked());
  final there = CreationLocation.of(makeMarked());
  if (!tracked) {
    if (here != null || there != null) {
      throw StateError('expected no creation locations, got $here and $there');
    }
    return;
  }
  if (here == null || !here.file.endsWith('main.dart')) {
    throw StateError('expected a location in main.dart, got $here');
  }
  if (there == null || !there.file.endsWith('maker.dart')) {
    throw StateError('expected a location in maker.dart, got $there');
  }
  if (there.line != 4) {
    throw StateError('expected maker.dart line 4, got $there');
  }
}
