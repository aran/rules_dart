/// Doubles [length]; called through `package:shapes`, so its coverage shows
/// that a library's own dependencies are reported too.
int twice(int length) {
  return length * 2; // covered
}
