// Property: a `dart_binary` in the `exe`, `kernel` and `aot-snapshot` modes
// is the same bytes however often, and wherever, it is compiled. The same
// entrypoint is built in three packages to outputs of the same name; the
// third's directory is longer than the others', because a path that ends up
// in the bytes shows in the length of what it displaces. Identical bytes
// across the three mean neither the location nor the path's length (nor the
// build's temporary directory) is in the output, which is what makes a cache
// hit on another machine possible.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _packages = ['a', 'b', 'a_much_longer_directory_name'];

void main() {
  final r = Runfiles.create();
  final exe = Platform.isWindows ? 'hello_exe.exe' : 'hello_exe';
  var failures = 0;
  for (final name in [exe, 'hello_kernel.dill', 'hello_aot_snapshot.aot']) {
    final bytes = [
      for (final package in _packages)
        File(
          r.rlocation(
            '_main/dart/tests/reproducible_modes_fixture/$package/$name',
          ),
        ).readAsBytesSync(),
    ];
    for (var i = 1; i < bytes.length; i++) {
      final a = bytes.first;
      final b = bytes[i];
      var first = -1;
      for (var j = 0; j < a.length && j < b.length; j++) {
        if (a[j] != b[j]) {
          first = j;
          break;
        }
      }
      if (a.length != b.length || first != -1) {
        failures++;
        stderr.writeln(
          'FAIL: $name differs between ${_packages.first} and ${_packages[i]} '
          '(${a.length} vs ${b.length} bytes, first difference at $first)',
        );
      }
    }
    stdout.writeln('checked $name');
  }
  exit(failures == 0 ? 0 : 1);
}
