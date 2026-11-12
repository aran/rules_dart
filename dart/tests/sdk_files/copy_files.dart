/// `copy_files @<param file>`, the file holding `<out dir>` then
/// `<relative path> <source>` pairs, one argument a line: copies each source to
/// its path under the output directory, keeping its mode.
library;

import 'dart:io';

void main(List<String> argv) {
  final args = File(argv.single.substring(1)).readAsLinesSync();
  final out = args.first;
  for (var i = 1; i < args.length; i += 2) {
    final target = File('$out/${args[i]}');
    target.parent.createSync(recursive: true);
    File(args[i + 1]).copySync(target.path);
  }
}
