import 'package:units/units.dart';

/// The area of a [width] by [height] rectangle; the plain-`main()` test calls
/// it.
int area(int width, int height) {
  return width * height; // covered
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
