import 'dart:io';

import 'package:path/path.dart' as p;

void main() {
  // The fixture's proof is its stdout, so `avoid_print` is satisfied by
  // writing to the stream directly rather than by dropping the output.
  final joined = p.join('usr', 'local', 'bin');
  stdout.writeln('Joined: $joined');

  final ext = p.extension('photo.jpg');
  stdout.writeln('Extension: $ext');

  final base = p.basename('/path/to/file.txt');
  stdout.writeln('Basename: $base');

  final dir = p.dirname('/path/to/file.txt');
  stdout.writeln('Dirname: $dir');

  // Verify results
  assert(ext == '.jpg', 'Expected .jpg but got $ext');
  assert(base == 'file.txt', 'Expected file.txt but got $base');

  stdout.writeln('All pub dependency tests passed!');
}
