// Runs the Gazelle binary (with the Dart language) over small workspaces it
// builds in temp directories and checks the BUILD files it writes.
//
// Arguments: the gazelle binary's runfiles path, then the runfiles paths of
// the sample sources copied into the first workspace.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

late final String gazelleBin;
var failed = false;

void fail(String message) {
  stdout.writeln('FAIL: $message');
  failed = true;
}

/// A throwaway repository root.
class Workspace {
  Workspace() : root = Directory.systemTemp.createTempSync('gazelle_e2e_');

  final Directory root;

  String path(String rel) => '${root.path}/$rel';

  void write(String rel, String content) {
    final file = File(path(rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String rel) => File(path(rel)).readAsStringSync();

  /// `WORKSPACE` and an empty root `BUILD.bazel`, the markers Gazelle needs.
  void markRoot({String build = ''}) {
    write('WORKSPACE', '');
    write('BUILD.bazel', build);
  }

  /// Runs Gazelle on [target] (a path relative to the root; the root when
  /// omitted), with any [extra] flags before it.
  void gazelle({String target = '', List<String> extra = const []}) {
    final result = Process.runSync(gazelleBin, [
      '-lang',
      'dart',
      '-repo_root',
      root.path,
      ...extra,
      target.isEmpty ? root.path : path(target),
    ]);
    if (result.exitCode != 0) {
      fail(
        'gazelle exited ${result.exitCode}\n${result.stdout}${result.stderr}',
      );
    }
  }

  void check(String file, String pattern, String desc) {
    final content = read(file);
    if (content.contains(pattern)) {
      stdout.writeln('PASS: $file contains $desc');
    } else {
      fail(
        '$file missing $desc\n  Contents:\n'
        '${content.split('\n').map((l) => '    $l').join('\n')}',
      );
    }
  }

  void checkAbsent(String file, String pattern, String desc) {
    if (read(file).contains(pattern)) {
      fail('$file: $desc');
    } else {
      stdout.writeln('PASS: $desc');
    }
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  gazelleBin = runfiles.rlocation(args[0]);
  final samples = args.sublist(1);

  // ---- Basic generation from the sample sources -------------------------
  var w = Workspace();
  for (final rlocation in samples) {
    // `_main/gazelle/lib/greeter.dart` -> `lib/greeter.dart`.
    const prefix = '_main/gazelle/';
    if (!rlocation.startsWith(prefix)) {
      throw StateError('$rlocation is not under $prefix');
    }
    final rel = rlocation.substring(prefix.length);
    w.write(rel, File(runfiles.rlocation(rlocation)).readAsStringSync());
  }
  w.markRoot();
  w.gazelle();

  w.check('BUILD.bazel', 'dart_library', 'dart_library rule');
  for (final src in [
    'greeter.dart',
    'platform_client.dart',
    'stub.dart',
    'io_impl.dart',
    'web_impl.dart',
  ]) {
    w.check('BUILD.bazel', '"lib/$src"', '$src in srcs');
  }
  w.check('bin/BUILD.bazel', 'dart_binary', 'dart_binary rule');
  w.check('bin/BUILD.bazel', 'hello.dart', 'hello.dart as main');
  w.check('bin/BUILD.bazel', 'show_import', 'show_import rule (show modifier)');
  w.check(
    'bin/BUILD.bazel',
    'deferred_import',
    'deferred_import rule (deferred modifier)',
  );
  w.check('bin/BUILD.bazel', '//:lib', '//:lib dep for modifier imports');
  w.check('test/BUILD.bazel', 'dart_test', 'dart_test rule');
  w.check('test/BUILD.bazel', 'greeter_test.dart', 'greeter_test.dart as main');
  w.dispose();
  if (failed) {
    stdout.writeln('SOME TESTS FAILED');
    exit(1);
  }
  stdout.writeln('--- Basic tests passed ---');

  // ---- dart_pub_deps_repo directive -------------------------------------
  w = Workspace();
  w.write('WORKSPACE', '');
  w.write('BUILD.bazel', '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('lib/app.dart', '''
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
''');
  w.gazelle();
  w.check('BUILD.bazel', '@pub_deps//:shelf', '@pub_deps//:shelf dep');
  w.check('BUILD.bazel', '@pub_deps//:path', '@pub_deps//:path dep');
  w.dispose();

  // ---- dart_package_name directive emits package_name -------------------
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_package_name my_app\n');
  w.write('lib/app.dart', "String hello() => 'hello';\n");
  w.gazelle();
  w.check('BUILD.bazel', 'name = "my_app"', 'name = my_app');
  w.check('BUILD.bazel', 'package_name = "my_app"', 'package_name = my_app');
  w.dispose();

  // ---- pubspec.yaml auto-detection of the package name ------------------
  w = Workspace();
  w.markRoot();
  w.write('pubspec.yaml', 'name: my_server\n');
  w.write('lib/app.dart', "String greet() => 'hi';\n");
  w.gazelle();
  w.check('BUILD.bazel', 'name = "my_server"', 'name = my_server');
  w.check(
    'BUILD.bazel',
    'package_name = "my_server"',
    'package_name = my_server',
  );
  w.dispose();

  // ---- gazelle:resolve directive override -------------------------------
  w = Workspace();
  w.write('WORKSPACE', '');
  w.write(
    'BUILD.bazel',
    '# gazelle:resolve dart shelf //third_party:shelf_custom\n',
  );
  w.write('lib/app.dart', '''
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
''');
  w.gazelle();
  w.check(
    'BUILD.bazel',
    '//third_party:shelf_custom',
    'gazelle:resolve override for shelf',
  );
  w.check('BUILD.bazel', '@path', 'default resolution for path');
  w.dispose();

  // ---- @JsonSerializable -> convenience macro ---------------------------
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: my_models\nenvironment:\n  sdk: ^3.11.0\n');
  w.write('lib/user.dart', '''
import 'package:json_annotation/json_annotation.dart';
part 'user.g.dart';
@JsonSerializable()
class User {
  User({required this.id, required this.name});
  final int id;
  final String name;
}
''');
  w.gazelle();
  // A single-annotation file emits the macro, which wires the shard and
  // combining stages itself, not the primitive chain; the package's library
  // holds the source and what the macro generates.
  w.check(
    'BUILD.bazel',
    'json_serializable_codegen(',
    'json_serializable_codegen macro call',
  );
  w.check('BUILD.bazel', 'name = "user_codegen"', 'macro target name');
  w.check(
    'BUILD.bazel',
    'srcs = [\n        "lib/user.dart",\n        ":user_codegen",\n    ],',
    "the source and the macro's outputs in the package's library",
  );
  w.check(
    'BUILD.bazel',
    'package_name = "my_models"',
    'package_name propagated to macro',
  );
  w.check(
    'BUILD.bazel',
    'language_version = ',
    'language_version propagated to macro',
  );
  w.check(
    'BUILD.bazel',
    'load("@rules_dart//dart/ext/json_serializable:defs.bzl"',
    'json_serializable_codegen load',
  );
  final macroBuild = w.read('BUILD.bazel');
  if ([
    '_user_json_serializable_gen',
    '_user_combined',
    'combining_shim:bin',
  ].any(macroBuild.contains)) {
    fail('single-annotation file emitted primitive chain instead of macro');
  } else {
    stdout.writeln('PASS: primitive chain suppressed (macro used)');
  }
  w.dispose();

  // ---- multi-annotation cascade: @Freezed + @JsonSerializable -----------
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: my_events\n');
  w.write('lib/event.dart', '''
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_annotation/json_annotation.dart';
part 'event.freezed.dart';
part 'event.g.dart';
@Freezed()
@JsonSerializable()
abstract class Event with _\$Event {
  const factory Event({required String type, required int sequence}) = _Event;
  factory Event.fromJson(Map<String, Object?> json) => _\$EventFromJson(json);
}
''');
  w.gazelle();
  // Freezed (PartBuilder) runs before JsonSerializable (SharedPart), then a
  // combining stage on the JsonSerializable shard.
  w.check('BUILD.bazel', '_event_freezed_gen', 'freezed stage');
  w.check('BUILD.bazel', '_event_json_serializable_gen', 'json shard stage');
  w.check('BUILD.bazel', '_event_combined', 'combining stage');
  w.dispose();

  // ---- only the files a codegen target produces are left out -----------
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: my_skip\n');
  w.write('lib/keep.dart', 'class Keep {}\n');
  w.write('lib/notes.g.dart', '// Written by hand.\nclass Notes {}\n');
  w.write('lib/user.dart', '''
import 'package:json_annotation/json_annotation.dart';
part 'user.g.dart';
@JsonSerializable()
class User {}
''');
  w.write('lib/user.g.dart', "part of 'user.dart';\n");
  w.gazelle();
  w.checkAbsent(
    'BUILD.bazel',
    '"lib/user.g.dart"',
    "the checked-in output of user.dart's codegen left out",
  );
  w.check('BUILD.bazel', '"lib/notes.g.dart"', 'a .g.dart no target produces');
  w.check('BUILD.bazel', '"lib/keep.dart"', 'the plain source');
  w.dispose();

  // ---- analysis options: per-directory targets and the root config ------
  w = Workspace();
  w.markRoot();
  w.write('analysis_options.yaml', 'linter: {rules: {}}\n');
  w.write(
    'tools/analysis_options.yaml',
    'include: package:very_good_analysis/analysis_options.yaml\n',
  );
  w.gazelle();

  w.check(
    'BUILD.bazel',
    'dart_analysis_options(',
    'root dart_analysis_options',
  );
  w.check(
    'tools/BUILD.bazel',
    'name = "analysis_options"',
    'nested options target',
  );
  w.check(
    'tools/BUILD.bazel',
    '"@very_good_analysis"',
    'package: include resolved into deps',
  );
  w.check('BUILD.bazel', 'dart_analysis_config(', 'dart_analysis_config');
  w.check('BUILD.bazel', '":analysis_options",', 'root options listed');
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested options listed',
  );

  // A second full run changes nothing (what `gazelle -mode=diff` checks in CI).
  final firstRoot = w.read('BUILD.bazel');
  final firstTools = w.read('tools/BUILD.bazel');
  w.gazelle();
  if (w.read('BUILD.bazel') == firstRoot &&
      w.read('tools/BUILD.bazel') == firstTools) {
    stdout.writeln('PASS: second run is a no-op');
  } else {
    fail('second run changed the BUILD files');
  }

  // Partial runs never drop entries they did not visit, and list nothing
  // outside what they visit.
  w.write('extra/analysis_options.yaml', 'linter: {rules: {}}\n');
  w.gazelle(target: 'tools');
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested entry kept by a run on tools/',
  );
  w.gazelle(extra: ['-r=false']);
  w.check(
    'BUILD.bazel',
    '"//tools:analysis_options",',
    'nested entry kept by a root-only run',
  );
  w.checkAbsent(
    'BUILD.bazel',
    '//extra',
    'a run that did not visit extra/ listed it',
  );
  w.gazelle();
  w.check(
    'BUILD.bazel',
    '"//extra:analysis_options",',
    'new directory listed by a full run',
  );

  File(w.path('extra/analysis_options.yaml')).deleteSync();
  w.gazelle();
  w.checkAbsent(
    'BUILD.bazel',
    '//extra',
    'a full run kept the entry of a deleted analysis_options.yaml',
  );

  // Removing every yaml never deletes the config: `.bazelrc` files name it.
  File(w.path('analysis_options.yaml')).deleteSync();
  File(w.path('tools/analysis_options.yaml')).deleteSync();
  w.gazelle();
  w.check(
    'BUILD.bazel',
    'dart_analysis_config(',
    'dart_analysis_config kept with nothing to list',
  );
  w.checkAbsent(
    'BUILD.bazel',
    ':analysis_options',
    'the empty config still lists a removed options target',
  );
  w.dispose();

  // ---- one library holds the whole of lib/ ----------------------------
  // Directories under lib/, and import cycles between them, mean nothing to
  // Dart: the package's library, at its root, holds every file, with what
  // the codegen of an annotated source in a subdirectory generates, which
  // is named for the source's path under lib/.
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: two\n');
  w.write('lib/two.dart', "import 'src/a/a.dart';\n");
  w.write(
    'lib/src/a/a.dart',
    "import '../b/b.dart';\nimport '../m/user.dart';\n",
  );
  w.write('lib/src/b/b.dart', "import 'package:two/src/a/a.dart';\n");
  w.write('lib/src/m/user.dart', '''
import 'package:json_annotation/json_annotation.dart';
import '../b/b.dart';
part 'user.g.dart';
@JsonSerializable()
class User {}
''');
  w.gazelle();
  w.check(
    'BUILD.bazel',
    'srcs = [\n        "lib/src/a/a.dart",\n        "lib/src/b/b.dart",\n'
        '        "lib/src/m/user.dart",\n        "lib/two.dart",\n'
        '        ":src/m/user_codegen",\n    ],',
    'every file under lib/ in the one library, with what the codegen generates',
  );
  w.check(
    'BUILD.bazel',
    'name = "src/m/user_codegen"',
    "the annotated source's codegen",
  );
  w.check(
    'BUILD.bazel',
    'asset_deps = [\n        "lib/src/a/a.dart",\n        "lib/src/b/b.dart",\n    ],',
    'the files the source reaches by imports, cycle included, staged for its generator',
  );
  for (final d in ['lib', 'lib/src/a', 'lib/src/b', 'lib/src/m']) {
    if (File(w.path('$d/BUILD.bazel')).existsSync()) {
      fail('Gazelle wrote $d/BUILD.bazel');
    }
  }
  final oneRun = w.read('BUILD.bazel');
  w.gazelle();
  if (w.read('BUILD.bazel') == oneRun) {
    stdout.writeln('PASS: a second run is a no-op');
  } else {
    fail('a second run changed the BUILD file');
  }
  w.dispose();

  // ---- a test helper in a directory of its own -------------------------
  w = Workspace();
  w.markRoot(build: '# gazelle:dart_pub_deps_repo pub_deps\n');
  w.write('pubspec.yaml', 'name: helped\n');
  w.write('lib/helped.dart', 'class Helped {}\n');
  w.write(
    'test/util/fixture.dart',
    "import 'package:path/path.dart';\nimport '../shared.dart';\n",
  );
  w.write('test/shared.dart', "import 'package:helped/helped.dart';\n");
  w.write('test/a_test.dart', "import 'util/fixture.dart';\n");
  w.gazelle();
  w.check(
    'test/util/BUILD.bazel',
    'filegroup(\n    name = "util",\n    srcs = ["fixture.dart"],\n'
        '    visibility = ["//test:__subpackages__"],\n)',
    'the helper directory lends its helpers',
  );
  w.check(
    'test/BUILD.bazel',
    'srcs = [\n        "shared.dart",\n        "//test/util",\n    ],',
    "the test's srcs: its directory's helper and the helper filegroup",
  );
  w.check('test/BUILD.bazel', '"@pub_deps//:path"', "the helper's import");
  w.check('test/BUILD.bazel', '"//:helped"', "the helper's helper's import");
  File(w.path('test/a_test.dart')).writeAsStringSync('void main() {}\n');
  w.gazelle();
  w.checkAbsent(
    'test/util/BUILD.bazel',
    'filegroup',
    'an unused filegroup kept',
  );
  w.dispose();

  if (failed) {
    stdout.writeln('SOME TESTS FAILED');
    exit(1);
  }
  stdout.writeln('All Gazelle e2e tests passed');
}
