import 'package:generated/generated.dart';
import 'package:shapes/shapes.dart';

import 'support.dart';

void main() {
  if (area(2, 3) != 6) throw StateError('area(2, 3) is not 6');
  if (scaled(2) != 6) throw StateError('scaled(2) is not 6');
  if (one() != 1) throw StateError('one() is not 1');
  if (support() != 3) throw StateError('support() is not 3');
}
