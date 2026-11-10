import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `dart_test` lays out its own scratch workspace from the manifest, so the
/// test process is no judge of what a program gets under `--noenable_runfiles`.
/// A separate binary (`lookup_probe`) started with Bazel's own RUNFILES_*
/// variables is: it runs `Runfiles.create()` exactly as a user's tool would.
void main() {
  test(
    'a program resolves files inside a tree artifact from the runfiles '
    'Bazel gave it (a forest, or only a manifest under --noenable_runfiles)',
    () {
      final exe = Platform.isWindows ? 'lookup_probe.exe' : 'lookup_probe';
      final probe = Runfiles.create().rlocation('_main/dart/runfiles/$exe');
      const base = '_main/dart/runfiles/test/tree_artifact/out_dir';
      final r = Process.runSync(probe, ['$base/top.txt', '$base/sub/deep.txt']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final paths = const LineSplitter()
          .convert(r.stdout as String)
          .map((l) => jsonDecode(l) as String)
          .toList();
      expect(File(paths[0]).readAsStringSync().trim(), 'top');
      expect(File(paths[1]).readAsStringSync().trim(), 'deep');
    },
  );
}
