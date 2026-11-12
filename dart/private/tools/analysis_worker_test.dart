import 'dart:async';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `analyze_runner` as Bazel runs it as a persistent worker: what it answers,
/// and that its analysis server ends with it however it ends.
///
/// Arguments are the runfiles paths of `analyze_runner`, `analysis_host.dart`
/// and a copy of the SDK's `analyze` file set.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  // A copy of the SDK's `analyze` file set: the files the actions get.
  final dart =
      '${runfiles.rlocation(args[2])}/bin/dart'
      '${Platform.isWindows ? '.exe' : ''}';
  final runner = runfiles.rlocation(args[0]);
  final host = runfiles.rlocation(args[1]);

  late Directory scratch;
  late Process worker;
  late BazelWorkerDriver driver;
  setUp(() {
    scratch = Directory(
      Directory.systemTemp
          .createTempSync('analysis_worker_test')
          .resolveSymbolicLinksSync(),
    );
    final execroot = Directory('${scratch.path}/output_base/execroot/_main')
      ..createSync(recursive: true);
    // A temporary directory of its own, as a hardened sandbox gives it.
    final tmp = Directory('${scratch.path}/tmp')..createSync();
    driver = BazelWorkerDriver(
      () async => worker = await Process.start(
        runner,
        ['--host', host, '--persistent_worker'],
        workingDirectory: execroot.path,
        environment: {
          if (Platform.isWindows) ...{
            'TEMP': tmp.path,
            'TMP': tmp.path,
          } else
            'TMPDIR': tmp.path,
        },
      ),
    );
  });
  tearDown(() async {
    await driver.terminateWorkers();
    scratch.deleteSync(recursive: true);
  });

  /// The processes whose command line names [scratch]: the worker's server.
  List<String> servers() {
    final out = Process.runSync('pgrep', [
      '-f',
      'analysis_host.dart.*${scratch.path}',
    ]);
    return (out.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Server caches the worker made.
  List<String> caches() => [
    for (final e in Directory('${scratch.path}/tmp').listSync())
      if (e.path.contains('dart_analysis_worker-')) e.path,
  ];

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(condition(), isTrue);
  }

  String project(Map<String, String> files) {
    final root = Directory('${scratch.path}/project');
    if (root.existsSync()) root.deleteSync(recursive: true);
    for (final MapEntry(:key, :value) in {
      'pubspec.yaml': 'name: probe\nenvironment:\n  sdk: ^3.6.0\n',
      '.dart_tool/package_config.json':
          '{"configVersion":2,"packages":[{"name":"probe","rootUri":"../",'
          '"packageUri":"lib/","languageVersion":"3.10"}]}\n',
      ...files,
    }.entries) {
      File('${root.path}/$key')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    return root.path;
  }

  Future<WorkResponse> analyze(Map<String, String> files) => driver.doWork(
    WorkRequest(
      arguments: [
        '--dart',
        dart,
        '--project',
        project(files),
        '--stamp',
        '${scratch.path}/stamp',
        '--fatal-infos',
      ],
    ),
  );

  test(
    'answers requests, writing the stamp only for a clean project',
    () async {
      final broken = await analyze({'lib/a.dart': 'int a() => "";\n'});
      expect(broken.exitCode, 3);
      expect(broken.output, contains('return_of_invalid_type'));
      expect(File('${scratch.path}/stamp').existsSync(), isFalse);
      final clean = await analyze({'lib/a.dart': 'int a() => 1;\n'});
      expect(clean.exitCode, 0, reason: clean.output);
      expect(File('${scratch.path}/stamp').existsSync(), isTrue);
      expect(servers(), hasLength(1));
      expect(caches(), hasLength(1));
    },
  );

  for (final (how, end) in <(String, void Function())>[
    ('killed', () => worker.kill(ProcessSignal.sigkill)),
    ('sent SIGTERM', () => worker.kill(ProcessSignal.sigterm)),
    ('left with its input closed', () => worker.stdin.close()),
  ]) {
    test('takes its server and cache with it when $how', () async {
      expect((await analyze({'lib/a.dart': 'int a() => 1;\n'})).exitCode, 0);
      expect(servers(), hasLength(1));
      end();
      await worker.exitCode.timeout(const Duration(seconds: 10));
      await until(() => servers().isEmpty);
      await until(() => caches().isEmpty);
    });
  }
}
