import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

void main() {
  // Test path package
  final joined = p.join('usr', 'local', 'bin');
  stdout.writeln('Path joined: $joined');

  // Test collection package - use groupListsBy which is unique to collection
  final numbers = [3, 1, 4, 1, 5, 9, 2, 6];
  final grouped = numbers.groupListsBy((n) => n.isEven ? 'even' : 'odd');
  stdout.writeln('Grouped: $grouped');

  // Test firstWhereOrNull (another collection extension)
  final found = numbers.firstWhereOrNull((n) => n > 7);
  stdout.writeln('First > 7: $found');

  // Verify results
  assert(grouped['even'] != null, 'Should have even group');
  assert(grouped['odd'] != null, 'Should have odd group');
  assert(found == 9, 'First > 7 should be 9');

  stdout.writeln('All pub_lock tests passed!');
}
