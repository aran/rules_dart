import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `coverage_converter`'s command line, as a test rule that collects coverage
/// from a VM of its own runs it: `package:coverage` JSON in, LCOV by workspace
/// path out, without the lines their sources ignore.
///
/// The argument is the runfiles path of `coverage_converter`.
void main(List<String> args) {
  final converter = Runfiles.create().rlocation(args[0]);

  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('coverage_conv'));
  tearDown(() => scratch.deleteSync(recursive: true));

  File write(String name, String content) {
    final file = File('${scratch.path}/$name');
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync(content);
  }

  /// What a process a test starts has: Bazel's coverage manifest and the
  /// test's runfiles, where the sources are.
  Map<String, String> bazel() => {
    'COVERAGE_MANIFEST': write(
      'manifest.txt',
      'app/lib/app.dart\n'
          'app/test/app_test.dart\n'
          'bazel-out/k8-fastbuild/bin/app/lib/app.g.dart\n',
    ).path,
    'RUNFILES_DIR': '${scratch.path}/runfiles',
  };

  /// Puts a source in the runfiles, as the test carries it.
  void source(String name, [String content = '\n\n\n\n\n\n\n']) =>
      write('runfiles/_main/$name', content);

  /// Runs the converter with [env] and none of this test's own coverage or
  /// runfiles variables. Not an empty environment: Windows refuses to start a
  /// process with one.
  Future<ProcessResult> run(Map<String, String> env, List<String> flags) =>
      Process.run(
        converter,
        flags,
        environment: {
          for (final MapEntry(:key, :value) in Platform.environment.entries)
            if (!key.startsWith('COVERAGE_') &&
                !key.startsWith('RUNFILES_') &&
                key != 'JAVA_RUNFILES')
              key: value,
          ...env,
        },
        includeParentEnvironment: false,
      );

  /// What `package:coverage`'s `collect` returns: `hits` is line and count
  /// pairs, flattened.
  String hitmap(List<Map<String, Object>> entries) =>
      jsonEncode({'type': 'CodeCoverage', 'coverage': entries});

  late String sources;
  late String output;
  setUp(() {
    sources = write(
      'sources.json',
      jsonEncode({
        'packages': {
          'app': ['app/lib/'],
        },
        'files': {
          'app/lib/app.dart': '_main/app/lib/app.dart',
          'app/test/app_test.dart': '_main/app/test/app_test.dart',
          'bazel-out/k8-fastbuild/bin/app/lib/app.g.dart':
              '_main/app/lib/app.g.dart',
        },
      }),
    ).path;
    output = '${scratch.path}/coverage/test.dat';
    Directory('${scratch.path}/coverage').createSync();
    source('app/lib/app.dart');
    source('app/test/app_test.dart');
    source('app/lib/app.g.dart');
  });

  test('writes LCOV by workspace path from hit maps of another VM', () async {
    write(
      'maps/a/suite_1.json',
      hitmap([
        {
          'source': 'package:app/app.dart',
          'script': {'uri': 'package:app/app.dart'},
          'hits': [3, 1, 4, 0, 5, 2],
        },
        {
          'source': 'org-dartlang-root:///app/test/app_test.dart',
          'hits': [2, 1],
        },
        {
          'source': 'package:app/app.g.dart',
          'hits': [1, 0],
        },
        {
          'source': 'dart:core',
          'hits': [1, 7],
        },
        {
          'source': 'package:flutter/widgets.dart',
          'hits': [1, 7],
        },
      ]),
    );
    write(
      'maps/suite_2.json',
      hitmap([
        {
          'source': 'package:app/app.dart',
          'hits': [3, 2, 6, 0],
        },
      ]),
    );
    write('maps/notes.txt', 'not coverage');

    final result = await run(bazel(), [
      '--hitmaps=${scratch.path}/maps',
      '--sources=$sources',
      '--output=$output',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      File(output).readAsStringSync(),
      'SF:app/lib/app.dart\n'
      'DA:3,3\n'
      'DA:4,0\n'
      'DA:5,2\n'
      'DA:6,0\n'
      'LH:2\n'
      'LF:4\n'
      'end_of_record\n'
      'SF:app/test/app_test.dart\n'
      'DA:2,1\n'
      'LH:1\n'
      'LF:1\n'
      'end_of_record\n'
      'SF:bazel-out/k8-fastbuild/bin/app/lib/app.g.dart\n'
      'DA:1,0\n'
      'LH:0\n'
      'LF:1\n'
      'end_of_record\n',
    );
    expect(File('$output.partial').existsSync(), isFalse);
  });

  test('leaves out the lines and files the sources ignore', () async {
    source(
      'app/lib/app.dart',
      'int a() => 1;\n'
          'int b() => 2; // coverage:ignore-line\n'
          '// coverage:ignore-start\n'
          'int c() => 3;\n'
          '// coverage:ignore-end\n'
          'int d() => 4;\n',
    );
    source('app/lib/app.g.dart', '// coverage:ignore-file\nint e() => 5;\n');
    write(
      'maps/suite.json',
      hitmap([
        {
          'source': 'package:app/app.dart',
          'hits': [1, 1, 2, 0, 3, 0, 4, 1, 5, 0, 6, 2],
        },
        {
          'source': 'package:app/app.g.dart',
          'hits': [2, 1],
        },
      ]),
    );

    final result = await run(bazel(), [
      '--hitmaps=${scratch.path}/maps',
      '--sources=$sources',
      '--output=$output',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      File(output).readAsStringSync(),
      'SF:app/lib/app.dart\n'
      'DA:1,1\n'
      'DA:6,2\n'
      'LH:2\n'
      'LF:2\n'
      'end_of_record\n',
    );
  });

  test('fails for a source the runfiles lack', () async {
    File('${scratch.path}/runfiles/_main/app/lib/app.dart').deleteSync();
    write(
      'maps/suite.json',
      hitmap([
        {
          'source': 'package:app/app.dart',
          'hits': [1, 1],
        },
      ]),
    );
    final result = await run(bazel(), [
      '--hitmaps=${scratch.path}/maps',
      '--sources=$sources',
      '--output=$output',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('app/lib/app.dart'));
    expect(File(output).existsSync(), isFalse);
  });

  test('fails for an ignore-start no ignore-end closes', () async {
    source('app/lib/app.dart', '// coverage:ignore-start\nint a() => 1;\n');
    write(
      'maps/suite.json',
      hitmap([
        {
          'source': 'package:app/app.dart',
          'hits': [2, 1],
        },
      ]),
    );
    final result = await run(bazel(), [
      '--hitmaps=${scratch.path}/maps',
      '--sources=$sources',
      '--output=$output',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('coverage:ignore-end'));
  });

  test('reports nothing for a hit map directory that does not exist', () async {
    final result = await run(bazel(), [
      '--hitmaps=${scratch.path}/none',
      '--sources=$sources',
      '--output=$output',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(File(output).readAsStringSync(), isEmpty);
  });

  test('refuses to run outside bazel coverage', () async {
    final result = await run({}, [
      '--hitmaps=${scratch.path}',
      '--sources=$sources',
      '--output=$output',
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('COVERAGE_MANIFEST'));
  });

  test('names a missing or unknown flag', () async {
    var result = await run(bazel(), ['--hitmaps=x', '--sources=$sources']);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('--output'));
    result = await run(bazel(), [
      '--hitmaps=x',
      '--sources=$sources',
      '--output=$output',
      '--bogus=1',
    ]);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('--bogus'));
  });
}
