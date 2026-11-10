// Behavioural proof that a compiled `dart_binary` does not depend on where it
// was built, and that its constants are the ones `dart compile exe` folds.
//
// Given a source path, `dart compile` names an entrypoint outside any package
// `file:///<absolute path>` — the sandbox directory, the output base — and the
// binary keeps that URI in its stack traces and in the private-name suffixes
// derived from it, so every rebuild elsewhere changes its bytes. The compile
// reads sources through a filesystem rooted at the exec root instead, so the
// URI is the same wherever the action runs.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _entrypoint =
    'org-dartlang-root:///dart/tests/kernel_uri_fixture/bin/probe.dart';

void main() {
  final runfiles = Runfiles.create();
  for (final name in ['probe', 'probe_with_asset', 'probe_beside_generated']) {
    final exe = runfiles.rlocation(
      '_main/dart/tests/kernel_uri_fixture/$name${Platform.isWindows ? '.exe' : ''}',
    );
    final result = Process.runSync(exe, []);
    if (result.exitCode != 0) {
      throw StateError('$name exited ${result.exitCode}: ${result.stderr}');
    }
    final out = result.stdout as String;
    if (!out.contains('product=true')) {
      throw StateError(
        '$name: an exe must see `dart.vm.product` true, as one built by '
        '`dart compile exe` from source does. Output:\n$out',
      );
    }
    if (!out.contains('($_entrypoint:') || out.contains('file://')) {
      throw StateError(
        '$name: the entrypoint must be named $_entrypoint, not by a path '
        'that depends on where it was built. Output:\n$out',
      );
    }
  }

  // The kernel the front end wrote names no path of where it was built: every
  // library not in a package is under the filesystem scheme, and the files it
  // read are not listed. (The platform's own comments hold `file:` URIs, so it
  // is a build directory that is looked for.)
  final kernel = File(
    runfiles.rlocation('_main/dart/tests/kernel_uri_fixture/probe_kernel.dill'),
  ).readAsBytesSync();
  final text = String.fromCharCodes(kernel);
  final built = RegExp(r'file:///[ -~]{0,200}?(bazel-out|execroot|sandbox)');
  if (built.firstMatch(text) case final match?) {
    throw StateError('the kernel names a build path: ${match.group(0)}');
  }
  if (!text.contains(_entrypoint)) {
    throw StateError('the kernel does not name $_entrypoint');
  }

  // The test itself goes through the same front end.
  final frame = StackTrace.current.toString().split('\n').first;
  if (!frame.contains(
    'org-dartlang-root:///dart/tests/kernel_uri_fixture/kernel_uri_test.dart',
  )) {
    throw StateError('dart_test named its entrypoint by a build path: $frame');
  }
  stdout.writeln('entrypoint URIs are build-location independent');
}
