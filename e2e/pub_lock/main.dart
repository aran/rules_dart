import 'package:path/path.dart' as p;
import 'package:collection/collection.dart';

void main() {
  // Test path package
  final joined = p.join('usr', 'local', 'bin');
  print('Path joined: $joined');

  // Test collection package - use groupListsBy which is unique to collection
  final numbers = [3, 1, 4, 1, 5, 9, 2, 6];
  final grouped = numbers.groupListsBy((n) => n.isEven ? 'even' : 'odd');
  print('Grouped: $grouped');

  // Test firstWhereOrNull (another collection extension)
  final found = numbers.firstWhereOrNull((n) => n > 7);
  print('First > 7: $found');

  // Verify results
  assert(grouped['even'] != null, 'Should have even group');
  assert(grouped['odd'] != null, 'Should have odd group');
  assert(found == 9, 'First > 7 should be 9');

  print('All pub_lock tests passed!');
}
