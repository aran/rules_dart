import 'package:path/path.dart' as p;

void main() {
  // Test basic path operations
  final joined = p.join('usr', 'local', 'bin');
  print('Joined: $joined');

  final ext = p.extension('photo.jpg');
  print('Extension: $ext');

  final base = p.basename('/path/to/file.txt');
  print('Basename: $base');

  final dir = p.dirname('/path/to/file.txt');
  print('Dirname: $dir');

  // Verify results
  assert(ext == '.jpg', 'Expected .jpg but got $ext');
  assert(base == 'file.txt', 'Expected file.txt but got $base');

  print('All pub dependency tests passed!');
}
