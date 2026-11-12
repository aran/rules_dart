import 'dart:convert';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `kernel_tool module` as Bazel runs it as a persistent worker, over the
/// SDK's real `kernel_worker`: a request's result depends only on the inputs
/// the request declares, as it would in a sandbox. Unsandboxed, the worker
/// runs in the exec root, where undeclared files sit beside declared ones.
///
/// Arguments are the runfiles paths of `kernel_tool` and of a copy of the
/// SDK's `kernel` file set.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final kernelTool = runfiles.rlocation(args[0]);
  final sdk = runfiles.rlocation(args[1]);
  final exe = Platform.isWindows ? '.exe' : '';
  final runtime = '$sdk/bin/dartaotruntime$exe';
  final snapshot = '$sdk/bin/snapshots/kernel_worker_aot.dart.snapshot';
  // Exec paths, as Bazel gives them: relative to the exec root.
  const platform = 'sdk/lib/_internal/vm_platform_product.dill';
  const librariesSpec = 'sdk/lib/libraries.json';

  late Directory execroot;
  late BazelWorkerDriver driver;
  late List<Process> workers;

  setUp(() {
    execroot = Directory.systemTemp.createTempSync('module_worker_test');
    for (final path in [platform, librariesSpec]) {
      final to = File('${execroot.path}/$path');
      to.parent.createSync(recursive: true);
      File('$sdk/${path.substring('sdk/'.length)}').copySync(to.path);
    }
    workers = [];
    driver = BazelWorkerDriver(
      () async {
        final worker = await Process.start(kernelTool, [
          'module',
          '--snapshot',
          snapshot,
          '--persistent_worker',
        ], workingDirectory: execroot.path);
        workers.add(worker);
        return worker;
      },
      maxWorkers: 1,
      maxRetries: 0,
    );
  });
  tearDown(() async {
    // Ended by its input, a worker stops its compiler and waits for it; a
    // killed one leaves it running in the exec root.
    for (final worker in workers) {
      await worker.stdin.close();
      await worker.exitCode;
    }
    execroot.deleteSync(recursive: true);
  });

  void write(String path, String content) => File('${execroot.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  /// Compiles package `app`'s [srcs] (exec paths) as `//app:lib`, declaring
  /// [srcs], the package config and the SDK's files, and returns the manifest
  /// and the module directory.
  ///
  /// [mapped] is a request as Bazel sends one under
  /// `--experimental_output_paths=strip` (measured with Bazel 9.3): the
  /// arguments, and the files in the worker's sandbox, name the output
  /// directory `bazel-out/cfg/bin`, while the request's inputs keep the
  /// configuration's own name.
  Future<(Map<String, dynamic>, String)> compile(
    List<String> srcs, {
    bool mapped = false,
  }) async {
    const unmapped = 'bazel-out/k8-fastbuild/bin';
    final bin = mapped ? 'bazel-out/cfg/bin' : unmapped;
    String declaredAs(String path) => path.replaceFirst(bin, unmapped);
    final config = '$bin/app/lib.module_package_config.json';
    write(
      config,
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'app',
            'rootUri': 'org-dartlang-root:///app/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    final declared = [...srcs, config, platform, librariesSpec];
    final response = await driver.doWork(
      WorkRequest(
        arguments: [
          '--label',
          '//app:lib',
          '--runtime',
          runtime,
          '--platform',
          platform,
          '--target',
          'vm',
          '--libraries-spec',
          librariesSpec,
          '--libraries-target',
          'vm',
          '--package-config',
          config,
          '--package-name',
          'app',
          '--package-root',
          'app',
          // As `add_kernel_roots` writes them: output directories first.
          if (srcs.any((s) => s.startsWith(bin))) ...['--multi-root', bin],
          '--multi-root',
          '.',
          for (final src in srcs) ...['--src', src],
          '--output-dir',
          '$bin/app/lib.modules',
          '--manifest-output',
          '$bin/app/lib.modules.json',
        ],
        inputs: [
          for (final path in declared.map(declaredAs))
            Input(path: path, digest: utf8.encode(path)),
        ],
      ),
    );
    expect(response.exitCode, 0, reason: response.output);
    final manifest = jsonDecode(
      File('${execroot.path}/$bin/app/lib.modules.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    return (manifest, '${execroot.path}/$bin/app/lib.modules');
  }

  test('a file the request does not declare is not there to import', () async {
    write('app/lib/a.dart', "import 'b.dart';\n\nString a() => b();\n");
    write('app/lib/b.dart', "String b() => 'undeclared';\n");
    final (manifest, _) = await compile(['app/lib/a.dart']);
    final module = (manifest['modules'] as List).single as Map;
    expect(module['status'], 'failed');
    expect(module['reason'], contains('b.dart'));
  });

  for (final mapped in [false, true]) {
    test(
      'an undeclared file in an output directory does not shadow the '
      'declared source at its path${mapped ? ', under path mapping' : ''}',
      () async {
        final bin = mapped ? 'bazel-out/cfg/bin' : 'bazel-out/k8-fastbuild/bin';
        write(
          'app/lib/a.dart',
          "import 'g.dart';\n\nString a() => 'declared';\n",
        );
        write('$bin/app/lib/g.dart', 'const g = 1;\n');
        // A stale output: Bazel leaves files of targets it no longer builds.
        write(
          '$bin/app/lib/a.dart',
          "import 'g.dart';\n\nString a() => 'stale';\n",
        );
        final (manifest, dir) = await compile([
          'app/lib/a.dart',
          '$bin/app/lib/g.dart',
        ], mapped: mapped);
        final modules = (manifest['modules'] as List)
            .cast<Map<String, Object?>>();
        expect(
          modules.map((m) => m['status']),
          everyElement('ok'),
          reason: '$modules',
        );
        final kernel = [
          for (final m in modules)
            ...File('$dir/${m['dill']}').readAsBytesSync(),
        ];
        // The kernel holds each library's source text.
        final text = latin1.decode(kernel);
        expect(
          text.contains("'stale'"),
          isFalse,
          reason: 'compiled the stale copy',
        );
        expect(text.contains("'declared'"), isTrue);
      },
    );
  }
}
