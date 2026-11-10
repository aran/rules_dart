import 'package:shapes/shapes.dart';

void main() {
  if (area(2, 3) != 6) throw StateError('area(2, 3) is not 6');
  if (scaled(2) != 6) throw StateError('scaled(2) is not 6');
}
