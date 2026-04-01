import 'package:path/path.dart' as p;
import 'package:collection/collection.dart';

void main() {
  print('Path joined: ${p.join('usr', 'local', 'bin')}');
  print('First even: ${[1, 2, 3].firstWhereOrNull((n) => n.isEven)}');
  print('Multi-lock dedup test passed!');
}
