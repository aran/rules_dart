/// `copy_files <out dir> (<relative path> <source>)...`: copies each source to
/// its path under the output directory, keeping its mode.
import 'dart:io';

void main(List<String> args) {
  final out = args.first;
  for (var i = 1; i < args.length; i += 2) {
    final target = File('$out/${args[i]}');
    target.parent.createSync(recursive: true);
    File(args[i + 1]).copySync(target.path);
  }
}
