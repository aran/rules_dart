import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs the Gazelle binary with the Dart plugin over a small Dart project in a
/// temporary workspace and checks the BUILD files it writes.
///
/// The first argument is the binary's runfiles path (`$(rlocationpath ...)`).
void main(List<String> args) {
  final gazelle = Runfiles.create().rlocation(args.first);
  final work = Directory.systemTemp.createTempSync('gazelle_test_');
  try {
    _run(gazelle, work);
  } finally {
    work.deleteSync(recursive: true);
  }
}

String _at(Directory dir, String relative) =>
    dir.uri.resolve(relative).toFilePath();

void _write(Directory dir, String relative, String content) {
  final file = File(_at(dir, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _run(String gazelle, Directory work) {
  _write(work, 'lib/greeter.dart', r'''
class Greeter {
  final String name;
  Greeter(this.name);
  String greet() => 'Hello, $name!';
}
''');
  _write(work, 'lib/formatter.dart', r'''
String formatGreeting(String greeting) {
  return '*** $greeting ***';
}
''');
  _write(work, 'bin/hello.dart', r'''
import 'package:lib/greeter.dart';

void main() {
  final greeter = Greeter('World');
  print(greeter.greet());
}
''');
  _write(work, 'test/greeter_test.dart', r'''
import 'package:lib/greeter.dart';

void main() {
  final greeter = Greeter('Test');
  assert(greeter.greet() == 'Hello, Test!');
}
''');
  _write(work, 'lib/src/util.dart', r'''
String shout(String s) => s.toUpperCase();
''');
  // The BUILD files earlier Gazelle versions wrote, one per directory under
  // lib/, which the package's library at its root replaces.
  _write(work, 'lib/BUILD.bazel', r'''
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "lib",
    srcs = [
        "formatter.dart",
        "greeter.dart",
    ],
    visibility = ["//visibility:public"],
    deps = ["//lib/src"],
)
''');
  _write(work, 'lib/src/BUILD.bazel', r'''
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "src",
    srcs = ["util.dart"],
    visibility = ["//visibility:public"],
)
''');
  // Gazelle needs a root marker.
  _write(work, 'BUILD.bazel', '');
  _write(work, 'WORKSPACE', '');

  // `-repo_root` makes it treat the temporary directory as a workspace.
  final result = Process.runSync(gazelle, [
    '-lang',
    'dart',
    '-repo_root',
    work.path,
    work.path,
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('FAIL: gazelle exited with ${result.exitCode}');
    exit(1);
  }

  var failed = false;

  void checkFile(String file) {
    if (File(_at(work, file)).existsSync()) {
      stdout.writeln('PASS: $file generated');
    } else {
      stdout.writeln('FAIL: $file was not generated');
      failed = true;
    }
  }

  void checkContains(String file, String text, String description) {
    final f = File(_at(work, file));
    if (!f.existsSync()) {
      stdout.writeln(
        'FAIL: $file does not contain $description (no such file)',
      );
      failed = true;
      return;
    }
    final content = f.readAsStringSync();
    if (content.contains(text)) {
      stdout.writeln('PASS: $file contains $description');
    } else {
      stdout.writeln('FAIL: $file does not contain $description');
      stdout.writeln('  Contents:');
      for (final line in content.split('\n')) {
        stdout.writeln('    $line');
      }
      failed = true;
    }
  }

  stdout.writeln('=== Checking generated BUILD files ===');

  // The package's root has its dart_library, holding every file under lib/,
  // and no BUILD file is left under lib/.
  checkContains('BUILD.bazel', 'dart_library', 'dart_library rule');
  checkContains('BUILD.bazel', '"lib/greeter.dart"', 'greeter.dart in srcs');
  checkContains(
    'BUILD.bazel',
    '"lib/formatter.dart"',
    'formatter.dart in srcs',
  );
  checkContains('BUILD.bazel', '"lib/src/util.dart"', 'util.dart in srcs');
  checkContains('BUILD.bazel', 'visibility', 'visibility attribute');
  for (final file in ['lib/BUILD.bazel', 'lib/src/BUILD.bazel']) {
    if (File(_at(work, file)).existsSync()) {
      stdout.writeln('FAIL: $file is still there');
      failed = true;
    } else {
      stdout.writeln('PASS: $file deleted');
    }
  }

  // bin/ has a dart_binary with a dep on //:lib (from the package:lib import).
  checkFile('bin/BUILD.bazel');
  checkContains('bin/BUILD.bazel', 'dart_binary', 'dart_binary rule');
  checkContains('bin/BUILD.bazel', 'hello.dart', 'hello.dart as main');
  checkContains(
    'bin/BUILD.bazel',
    '//:lib',
    'dep on //:lib from package:lib import',
  );

  // test/ has a dart_test with a dep on //:lib.
  checkFile('test/BUILD.bazel');
  checkContains('test/BUILD.bazel', 'dart_test', 'dart_test rule');
  checkContains(
    'test/BUILD.bazel',
    'greeter_test.dart',
    'greeter_test.dart as main',
  );
  checkContains(
    'test/BUILD.bazel',
    '//:lib',
    'dep on //:lib from package:lib import',
  );

  stdout.writeln();
  stdout.writeln('=== Generated BUILD files ===');
  for (final file in ['BUILD.bazel', 'bin/BUILD.bazel', 'test/BUILD.bazel']) {
    final f = File(_at(work, file));
    if (f.existsSync()) {
      stdout.writeln('--- $file ---');
      stdout.writeln(f.readAsStringSync());
    }
  }

  if (failed) {
    stdout.writeln('=== SOME TESTS FAILED ===');
    exit(1);
  }
  stdout.writeln('=== All Gazelle tests passed ===');
}
