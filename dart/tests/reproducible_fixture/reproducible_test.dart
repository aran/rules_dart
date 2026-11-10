// Behavioural proof that an `exe` or `aot-snapshot` is the same bytes however
// often, and wherever, it is compiled.
//
// On macOS gen_snapshot names the file it wrote in the Mach-O symbol table: a
// new temporary directory for each `exe`, the output path for an
// `aot-snapshot`. The two packages here compile one entrypoint to outputs of
// the same name, so any path left in them makes the pair differ. What removes
// the path re-signs the pages it changed, so the signatures must still verify:
// macOS will not run an arm64 executable whose signature does not.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  String path(String package, String name) => runfiles.rlocation(
    '_main/dart/tests/reproducible_fixture/$package/$name',
  );

  final exe = Platform.isWindows ? 'hello.exe' : 'hello';
  for (final name in [exe, 'hello_aot.aot']) {
    final a = File(path('a', name)).readAsBytesSync();
    final b = File(path('b', name)).readAsBytesSync();
    final differ =
        a.length != b.length ||
        Iterable<int>.generate(a.length).any((i) => a[i] != b[i]);
    if (differ) {
      throw StateError('$name differs between packages a and b');
    }
    if (Platform.isMacOS) {
      final verify = Process.runSync('codesign', [
        '--verify',
        '--strict',
        path('a', name),
      ]);
      if (verify.exitCode != 0) {
        throw StateError('$name: signature does not verify: ${verify.stderr}');
      }
    }
  }

  final run = Process.runSync(path('a', exe), []);
  if (run.exitCode != 0 || (run.stdout as String).trim() != 'hello') {
    throw StateError('$exe exited ${run.exitCode}: ${run.stdout}${run.stderr}');
  }
  stdout.writeln('compiled outputs are reproducible');
}
