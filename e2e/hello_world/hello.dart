import 'dart:io';

void main() {
  // `stdout.writeln` rather than `print`, which `avoid_print` rejects.
  stdout.writeln('Hello, World!');
}
