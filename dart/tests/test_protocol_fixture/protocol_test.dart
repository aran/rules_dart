import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Drives `:cases` through its `dart_test` launcher with the environment Bazel
/// sets for `--test_filter`, sharding and XML output.
///
/// The VM and the `package:test` runner are this test's own (the variables
/// are inherited): both tests depend on the same `package:test`.
void main(List<String> args) {
  final r = Runfiles.create();
  final launcher = r.rlocation(args[0]);
  const selected = 'alpha|beta|gamma|no package:test';
  final all = {'alpha', 'beta', 'gamma', 'no package:test default timeout'};

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('protocol_test.'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> run(Map<String, String> env) => Process.run(
    launcher,
    const [],
    environment: {
      'RULES_DART_DILL': '_main/dart/tests/test_protocol_fixture/cases.precompiled/'
          'dart/tests/test_protocol_fixture/cases_test.dart.vm_test.vm.app.dill',
      'RULES_DART_TEST_MAIN': args[1],
      'RULES_DART_TEST_PATH': 'dart/tests/test_protocol_fixture/cases_test.dart',
      'TEST_TMPDIR': tmp.path,
      ...env,
    },
  );

  Set<String> ran(String xml) => {
    for (final m in RegExp(r'<testcase name="([^"]*)"').allMatches(
      File(xml).readAsStringSync(),
    ))
      m.group(1)!,
  };

  test('--test_filter selects cases, and the 30 s default is off', () async {
    final xml = '${tmp.path}/filtered.xml';
    final result = await run({
      'TESTBRIDGE_TEST_ONLY': selected,
      'XML_OUTPUT_FILE': xml,
    });
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(ran(xml), all);
  });

  test('without a filter every case runs, and a failure is reported', () async {
    final xml = '${tmp.path}/all.xml';
    final result = await run({'XML_OUTPUT_FILE': xml});
    expect(result.exitCode, isNot(0));
    final report = File(xml).readAsStringSync();
    expect(ran(xml), {
      ...all,
      'filtered_out',
      'explicit timeout',
      'never runs',
    });
    expect(report, contains('failures="1"'));
    expect(report, contains('errors="1"'));
    expect(report, contains('did not exclude this case'));
  });

  test("a case's own timeout still applies", () async {
    final result = await run({'TESTBRIDGE_TEST_ONLY': 'explicit timeout'});
    expect(result.exitCode, isNot(0));
    expect('${result.stdout}', contains('Test timed out after 0.2 seconds'));
  });

  test('shards split the cases, each run once, and say so', () async {
    const shards = 3;
    final seen = <String>[];
    for (var i = 0; i < shards; i++) {
      final xml = '${tmp.path}/shard$i.xml';
      final status = '${tmp.path}/status$i';
      final result = await run({
        'TESTBRIDGE_TEST_ONLY': selected,
        'TEST_TOTAL_SHARDS': '$shards',
        'TEST_SHARD_INDEX': '$i',
        'TEST_SHARD_STATUS_FILE': status,
        'XML_OUTPUT_FILE': xml,
      });
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(File(status).existsSync(), isTrue);
      seen.addAll(ran(xml));
    }
    expect(seen.toSet(), all);
    expect(seen, hasLength(all.length));
  });

  test('a shard that draws no cases passes', () async {
    final result = await run({
      'TESTBRIDGE_TEST_ONLY': 'alpha',
      'TEST_TOTAL_SHARDS': '4',
      'TEST_SHARD_INDEX': '3',
    });
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('a filter that matches nothing in this target passes', () async {
    final result = await run({'TESTBRIDGE_TEST_ONLY': 'no_such_case'});
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test("a developer's own package:test config is not read", () async {
    // Under HOME, where the runner looks by default. Were it read,
    // `run_skipped` would run `never runs`, which fails.
    final home = Directory('${tmp.path}/home')..createSync();
    File('${home.path}/.dart_test.yaml')
        .writeAsStringSync('run_skipped: true\n');
    final result = await run({
      'TESTBRIDGE_TEST_ONLY': 'never runs',
      'HOME': home.path,
    });
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('arguments reach main', () async {
    // Checked indirectly elsewhere: this very test reads `args` under the
    // runner. Kept explicit so a regression names itself.
    expect(args, hasLength(2));
  });
}
