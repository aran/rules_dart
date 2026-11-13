import 'package:excluded/excluded.dart';
import 'package:units/units.dart';

/// The area of a [width] by [height] rectangle; the plain-`main()` test calls
/// it.
int area(int width, int height) {
  return width * height + zero(); // covered
}

/// The perimeter of a [width] by [height] rectangle; the `package:test` test
/// calls it.
int perimeter(int width, int height) {
  return twice(width + height); // covered
}

/// The volume of a box; no test calls it.
int volume(int width, int height, int depth) {
  return width * height * depth; // uncovered
}

/// The diagonal, squared; no test calls it, and the line says it need not be
/// covered, so the report names it neither way.
int diagonalSquared(int a, int b) => a * a + b * b; // coverage:ignore-line

// coverage:ignore-start
/// Called by the plain-`main()` test, and excluded from the report anyway.
int scaled(int length) {
  const factor = 3;
  return length * factor;
}
// coverage:ignore-end
