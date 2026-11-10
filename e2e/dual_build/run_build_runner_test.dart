import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// `build_runner` runs cleanly next to Bazel scaffolding (BUILD.bazel,
/// MODULE.bazel, `bazel-*` symlinks). Non-hermetic: needs the network for
/// `dart pub get`.
///
/// The first argument is the SDK launcher's runfiles path
/// (`$(rlocationpath ...)`).
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final dart = runfiles.rlocation(args.first);
  if (!File(dart).existsSync()) {
    _fail('dart binary not found at rlocation ${args.first}');
  }

  final pubspec = runfiles.rlocation('_main/fixture_pubspec.yaml');
  final userSource = runfiles.rlocation('_main/fixture_lib/user.dart');
  if (!File(pubspec).existsSync() || !File(userSource).existsSync()) {
    _fail(
      'fixture files missing in runfiles\n'
      '  pubspec: $pubspec\n'
      '  user_src: $userSource',
    );
  }

  final tmp = Directory.systemTemp.createTempSync('run_build_runner_test_');
  try {
    _run(tmp, dart, pubspec, userSource);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Never _fail(String message) {
  stderr.writeln('FAIL: $message');
  exit(1);
}

String _at(Directory dir, String relative) =>
    dir.uri.resolve(relative).toFilePath();

void _write(Directory dir, String relative, String content) {
  final file = File(_at(dir, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _run(Directory tmp, String dart, String pubspec, String userSource) {
  _write(tmp, 'pubspec.yaml', File(pubspec).readAsStringSync());
  _write(tmp, 'lib/user.dart', File(userSource).readAsStringSync());

  // Fake Bazel scaffolding at the package root. `package:build`'s asset walker
  // only descends into lib/, test/, bin/, web/ and tool/, so these are ignored.
  _write(tmp, 'BUILD.bazel', '''
load("@rules_dart//dart/ext/json_serializable:defs.bzl", "json_serializable_library")

json_serializable_library(
    name = "user",
    srcs = ["lib/user.dart"],
    package_name = "dual_build_fixture",
    language_version = "3.11",
    visibility = ["//visibility:public"],
)
''');
  _write(tmp, 'MODULE.bazel', '''
module(name = "dual_build_fixture")
bazel_dep(name = "rules_dart", version = "0.0.0")
''');

  // Bazel's convenience symlinks, pointed at /nonexistent to prove
  // `build_runner` neither follows nor stats them.
  for (final name in [
    'bazel-bin',
    'bazel-out',
    'bazel-testlogs',
    'bazel-dual_build_fixture',
  ]) {
    Link(_at(tmp, name)).createSync('/nonexistent');
  }

  // Scope the pub cache to the temporary directory so the test is
  // self-contained and leaves no trace on the host filesystem.
  final environment = {
    'PUB_CACHE': _at(tmp, '.pub-cache'),
    'HOME': tmp.path,
    'USERPROFILE': tmp.path,
  };

  void dartRun(List<String> arguments) {
    final result = Process.runSync(
      dart,
      arguments,
      workingDirectory: tmp.path,
      environment: environment,
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      _fail('dart ${arguments.join(' ')} exited with ${result.exitCode}');
    }
  }

  dartRun(['pub', 'get']);
  dartRun(['run', 'build_runner', 'build', '--delete-conflicting-outputs']);

  final generated = File(_at(tmp, 'lib/user.g.dart'));
  if (!generated.existsSync() || generated.lengthSync() == 0) {
    final listing = Directory(_at(tmp, 'lib'))
        .listSync()
        .map((e) => '  ${e.path}')
        .join('\n');
    _fail(
      'build_runner did not produce lib/user.g.dart (or file is empty)\n'
      '$listing',
    );
  }

  // Must be real generator output, not just a stub.
  final content = generated.readAsStringSync();
  if (!content.contains(r'_$UserToJson')) {
    _fail(
      r'lib/user.g.dart missing expected _$UserToJson generator output'
      '\n$content',
    );
  }

  print(
    'PASS: build_runner produced lib/user.g.dart with expected content in a '
    'Bazel-scaffolded workspace',
  );
}
