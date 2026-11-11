// Runs the executable among `BUILT` and checks what `SPLIT` says: split, the
// trace is addresses and a `.symbols` file came with it; not, the trace names
// its source and no symbols file was written.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  final split = Platform.environment['SPLIT'] == 'true';
  final built = Platform.environment['BUILT']!.split(' ');
  final symbols = built.where((p) => p.endsWith('.symbols')).toList();
  final executable = runfiles.rlocation(
    built.singleWhere((p) => !p.endsWith('.symbols')),
  );

  void fail(String why) {
    stderr.writeln(why);
    exit(1);
  }

  final result = Process.runSync(executable, const []);
  if (result.exitCode != 0) {
    fail('$executable exited ${result.exitCode}: ${result.stderr}');
  }
  final trace = result.stdout as String;
  final symbolic = trace.contains('main.dart');
  if (split) {
    if (symbols.length != 1) fail('expected one .symbols file, got $built');
    final file = File(runfiles.rlocation(symbols.single));
    if (file.lengthSync() == 0) fail('${file.path} is empty');
    if (symbolic || !trace.contains('build_id')) {
      fail('a split binary printed a symbolic trace:\n$trace');
    }
  } else {
    if (symbols.isNotEmpty) fail('no .symbols file expected, got $symbols');
    if (!symbolic) fail('the binary printed no symbolic trace:\n$trace');
  }
}
