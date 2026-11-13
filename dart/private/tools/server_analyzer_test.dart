import 'dart:async';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'analysis_server.dart';
import 'analyzer.dart';
import 'dart_cli.dart';
import 'server_analyzer.dart';

/// `ServerAnalyzer` as a persistent worker holds it: one analyzer, many
/// requests, against a fresh `dart analyze` or `dart fix` of the same files.
///
/// Arguments are the runfiles paths of `analysis_host.dart` and a copy of the
/// SDK's `analyze` file set.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  // A copy of the SDK's `analyze` file set: the files the actions get.
  final dart =
      '${runfiles.rlocation(args[1])}/bin/dart'
      '${Platform.isWindows ? '.exe' : ''}';
  final host = File(runfiles.rlocation(args[0])).resolveSymbolicLinksSync();

  late Directory scratch;
  late List<String> notes;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('server_analyzer_test');
    notes = [];
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  ServerAnalyzer analyzer({Duration idle = idleGap}) {
    final analyzer = ServerAnalyzer(
      host: host,
      cache: '${scratch.path}/worker',
      idle: idle,
      note: notes.add,
    );
    addTearDown(analyzer.close);
    return analyzer;
  }

  /// A project at [dir] with [files] beside a pubspec and package config.
  String project(String dir, Map<String, String> files) {
    final root = Directory('${scratch.path}/$dir');
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

  var fresh = 0;
  Future<({int exitCode, String stdout})> dartAnalyze(String project) async {
    final out = await DartCli(cache: '${scratch.path}/cli${++fresh}')
        .analyze(dart, project, fatalInfos: true);
    return (
      exitCode: out.exitCode,
      stdout: out.stdout
          .split('\n')
          .where((l) => !l.startsWith('Analyzing '))
          .join('\n')
          .trim(),
    );
  }

  Future<({int exitCode, String stdout})> analyze(
    ServerAnalyzer analyzer,
    String project,
  ) async {
    final out = await analyzer.analyze(dart, project, fatalInfos: true);
    return (exitCode: out.exitCode, stdout: out.stdout.trim());
  }

  bool alive(int pid) => Platform.isWindows
      ? (Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']).stdout
                as String)
            .contains(' $pid ')
      : Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(condition(), isTrue);
  }

  const broken = {'lib/a.dart': 'int a() => "";\n'};
  const clean = {'lib/a.dart': 'int a() => 1;\n'};

  test('answers each request as a fresh `dart analyze` does', () async {
    final server = analyzer();
    final a = project('a', broken);
    final b = project('b', clean);
    for (final dir in [a, b, a]) {
      expect(await analyze(server, dir), await dartAnalyze(dir));
    }
    expect(notes.where((n) => n.startsWith('Started')), hasLength(1));
  });

  test('answers again when its server dies during a request', () async {
    final server = analyzer();
    final dir = project('a', broken);
    final first = server.analyze(dart, dir, fatalInfos: true);
    await until(() => server.serverPid != null);
    final killed = server.serverPid!;
    Process.killPid(killed, ProcessSignal.sigkill);
    final out = await first;
    expect((
      exitCode: out.exitCode,
      stdout: out.stdout.trim(),
    ), await dartAnalyze(dir));
    expect(notes, contains(contains('exited unexpectedly')));
    expect(server.serverPid, isNot(killed));
    expect(await analyze(server, dir), await dartAnalyze(dir));
  });

  test('survives its server dying between requests', () async {
    final server = analyzer();
    final dir = project('a', broken);
    await analyze(server, dir);
    final killed = server.serverPid!;
    Process.killPid(killed, ProcessSignal.sigkill);
    await until(() => !alive(killed));
    // Let the exit be seen with nobody waiting on the server.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await analyze(server, dir), await dartAnalyze(dir));
    expect(server.serverPid, isNot(killed));
  });

  test('stops its server when idle, removing its cache', () async {
    final server = analyzer(idle: const Duration(seconds: 1));
    await analyze(server, project('a', clean));
    final pid = server.serverPid!;
    final cache = Directory('${scratch.path}/worker-1');
    expect(cache.existsSync(), isTrue);
    await until(() => server.serverPid == null);
    await until(() => !alive(pid));
    await until(() => !cache.existsSync());
    await until(() => notes.last.contains('idle'));
    // And starts another for the next request.
    expect(await analyze(server, project('a', broken)), isNot(isNull));
    expect(server.serverPid, isNotNull);
  });

  test('caches only in its own directories', () async {
    final server = analyzer();
    await analyze(server, project('a', clean));
    expect(
      scratch.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
      unorderedEquals(['a', 'worker-1']),
    );
    await server.close();
    expect(Directory('${scratch.path}/worker-1').existsSync(), isFalse);
  });

  test('starts a fresh server after a request that ran plugins', () async {
    final server = analyzer();
    // A plugin package with nothing to fetch: the server copies it into its
    // cache and runs it, whether or not it then works.
    final plugin = project('plugin', {
      'tools/analyzer_plugin/pubspec.yaml':
          'name: probe_plugin\nenvironment:\n  sdk: ^3.6.0\n',
      'tools/analyzer_plugin/bin/plugin.dart': 'void main(args, port) {}\n',
    });
    final dir = project('a', {
      ...clean,
      'analysis_options.yaml': 'analyzer:\n  plugins:\n    - probe_plugin\n',
      '.dart_tool/package_config.json':
          '{"configVersion":2,"packages":[{"name":"probe","rootUri":"../",'
          '"packageUri":"lib/","languageVersion":"3.10"},'
          '{"name":"probe_plugin","rootUri":"${Uri.directory(plugin)}",'
          '"packageUri":"lib/","languageVersion":"3.10"}]}\n',
    });
    await server.analyze(dart, dir, fatalInfos: true);
    expect(server.serverPid, isNull);
    expect(notes.last, contains('plugins'));
    await analyze(server, project('b', clean));
    expect(notes.where((n) => n.startsWith('Started')), hasLength(2));
  });

  test('fixes each request as a fresh `dart fix` does', () async {
    final server = analyzer();
    // Fixed in place, then given other content at the same path: what the
    // server was told of the first fix must not stand in for the file.
    final files = [
      {
        'analysis_options.yaml':
            'linter:\n  rules:\n    - prefer_single_quotes\n',
        'lib/a.dart': 'String a() => "a";\n',
      },
      {
        'analysis_options.yaml':
            'linter:\n  rules:\n    - prefer_single_quotes\n',
        'lib/a.dart': 'String a() => "b" + "c";\n',
      },
    ];
    for (final project_ in files) {
      final viaServer = project('fix', project_);
      expect((await server.fix(dart, viaServer)).exitCode, 0);
      final fixedByServer = File('$viaServer/lib/a.dart').readAsStringSync();
      final viaCli = project('fix', project_);
      expect(
        (await DartCli(
          cache: '${scratch.path}/cli${++fresh}',
        ).fix(dart, viaCli)).exitCode,
        0,
      );
      expect(fixedByServer, File('$viaCli/lib/a.dart').readAsStringSync());
      expect(fixedByServer, isNot(project_['lib/a.dart']));
    }
  });

  test('removes the caches of workers that are gone, and only those', () async {
    final gone = await Process.start(dart, ['--version']);
    await gone.exitCode;
    // A worker that is still running, other than the one asking.
    final script = File('${scratch.path}/running.dart')
      ..writeAsStringSync("import 'dart:io';\nvoid main() => stdin.drain();\n");
    final running = await Process.start(dart, [script.path]);
    addTearDown(() async {
      running.kill(ProcessSignal.sigkill);
      await running.exitCode;
    });
    String cache(int owner, int n) => (Directory(
      '${scratch.path}/dart_analysis_worker-$owner-$n',
    )..createSync()).path;
    final orphans = [cache(gone.pid, 1), cache(gone.pid, 2)];
    final kept = [
      cache(pid, 1),
      cache(pid, 7),
      cache(running.pid, 1),
      (Directory('${scratch.path}/other')..createSync()).path,
    ];
    removeOrphanedCaches(scratch.path);
    for (final dir in orphans) {
      expect(Directory(dir).existsSync(), isFalse, reason: dir);
    }
    for (final dir in kept) {
      expect(Directory(dir).existsSync(), isTrue, reason: dir);
    }
  });

  group('sdkIdentity', () {
    String sdk(String dir, {String version = '3.13.7', int size = 10}) {
      File('${scratch.path}/$dir/version')
        ..createSync(recursive: true)
        ..writeAsStringSync('$version\n');
      File('${scratch.path}/$dir/bin/snapshots/analysis_server.dart.snapshot')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(size, 0))
        ..setLastModifiedSync(DateTime.utc(2026));
      return '${scratch.path}/$dir/bin/dart';
    }

    test('is the same for the same SDK in another place', () {
      expect(sdkIdentity(sdk('one')), sdkIdentity(sdk('two')));
    });

    test('differs for another SDK in the same place', () {
      final before = sdkIdentity(sdk('one'));
      expect(sdkIdentity(sdk('one', version: '3.14.0')), isNot(before));
      expect(sdkIdentity(sdk('one', size: 11)), isNot(before));
    });
  });

  test(
    'the client fails a request, not itself, when the server dies',
    () async {
      final server = await AnalysisServer.start(
        dart,
        host: host,
        command: 'analyze',
        cache: '${scratch.path}/direct',
      );
      final analysis = server.reanalyze(project('a', broken));
      Process.killPid(server.pid, ProcessSignal.sigkill);
      await expectLater(analysis, throwsA(isA<ServerExited>()));
      await expectLater(
        server.request('server.getVersion'),
        throwsA(isA<ServerExited>()),
      );
      await server.kill();
    },
  );
}
