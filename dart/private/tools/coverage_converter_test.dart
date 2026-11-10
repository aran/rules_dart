import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `coverage_converter`'s command line, as a test rule that collects coverage
/// from a VM of its own runs it: `package:coverage` JSON in, LCOV by workspace
/// path out.
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

  Map<String, String> bazel() => {
    'COVERAGE_MANIFEST': write(
      'manifest.txt',
      'app/lib/app.dart\n'
          'app/test/app_test.dart\n'
          'bazel-out/k8-fastbuild/bin/app/lib/app.g.dart\n',
    ).path,
  };

  Future<ProcessResult> run(Map<String, String> env, List<String> flags) =>
      Process.run(
        converter,
        flags,
        environment: env,
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
      }),
    ).path;
    output = '${scratch.path}/coverage/test.dat';
    Directory('${scratch.path}/coverage').createSync();
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
