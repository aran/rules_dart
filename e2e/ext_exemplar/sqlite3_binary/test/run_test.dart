import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Acceptance for the `dart_binary` code_assets path: run the compiled
/// exe (which has the Bazel-built libsqlite3 bound as a code asset) and
/// confirm it resolves sqlite3 at runtime. This is what proves AOT
/// native-asset resolution on each CI platform.
void main() {
  test('sqlite3 dart_binary runs with the Bazel-bundled libsqlite3', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/sqlite3_binary/$exeName');
    final result = Process.runSync(exe, []);
    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout, contains('sqlite3 ok: hello'));
  });

  test('a `defines` entry survives the code-asset compile pipeline', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/sqlite3_binary/$exeName');
    final result = Process.runSync(exe, []);
    // Regression: `defines` used to be passed to the kernel -> exe stage,
    // where `dart compile` accepts `-D` and ignores it, so this printed
    // `channel: UNSET` with no build-time diagnostic.
    expect(result.stdout, contains('channel: bazel-e2e'));
  });

  test('the binary runs when copied out with its `.native` directory', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = File(r.rlocation('_main/sqlite3_binary/$exeName'));
    // What an install copies: the executable and the directory of libraries
    // beside it, links resolved. libsqlite3 comes from another repository,
    // so a path that held only in bazel-out or runfiles would fail here.
    final native = Directory('${exe.parent.path}/app.native');
    final dest = Directory.systemTemp.createTempSync('sqlite3_binary');
    addTearDown(() => dest.deleteSync(recursive: true));
    final copied = exe.copySync('${dest.path}/$exeName');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['+x', copied.path]);
    }
    final libs = Directory('${dest.path}/app.native')..createSync();
    for (final lib in native.listSync().whereType<File>()) {
      lib.copySync('${libs.path}/${lib.uri.pathSegments.last}');
    }
    final result = Process.runSync(copied.path, []);
    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout, contains('sqlite3 ok: hello'));
  });
}
