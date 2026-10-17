import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file/memory.dart';
import 'package:path/path.dart' as p;

void main() {
  // Test path package
  final joined = p.join('usr', 'local', 'bin');
  stdout.writeln('Path joined: $joined');

  // `file` resolves its paths through its own `path` context. This is the
  // package `path` this binary imports, reached through the same hub.
  final fs = MemoryFileSystem();
  final entry = fs.file(p.join('usr', 'local', 'bin', 'dart'));
  final base = fs.path.basename(entry.path);
  stdout.writeln('File path: ${entry.path}');
  assert(base == 'dart', 'Expected dart but got $base');
  stdout.writeln('File basename: $base');

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
