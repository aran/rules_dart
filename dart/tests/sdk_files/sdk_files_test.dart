/// Runs each use of the SDK against a copy of the SDK holding only that use's
/// file set (`sdk_file_set_copy`), so a set short of a file the use reads
/// fails here. A copy, because the `dart` launcher looks for the VM and the
/// snapshots beside its resolved path: through a link it would find the whole
/// SDK, as it does in a local sandbox, and only a remote executor, which has
/// nothing but an action's declared inputs, would show the gap.
///
/// Arguments: `<set>=<runfiles path of its copy>` per set, and the runfiles
/// paths of `analyzer_errors`, `analyze_runner` and `analysis_host` as
/// `<name>=<path>`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final paths = {
    for (final a in args)
      a.substring(0, a.indexOf('=')): runfiles.rlocation(
        a.substring(a.indexOf('=') + 1),
      ),
  };
  final exe = Platform.isWindows ? '.exe' : '';
  String sdk(String set) => paths[set]!;
  String tool(String set, String name) => '${sdk(set)}/bin/$name$exe';
  String snapshot(String set, String name) => '${sdk(set)}/bin/snapshots/$name';

  late Directory work;
  late String app;
  late String packages;
  late String productKernel;

  // What every step runs in: the SDK writes nothing into the real home.
  final environment = {
    'HOME': '',
    'APPDATA': '',
    'DART_SUPPRESS_ANALYTICS': 'true',
  };

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory ?? app,
      environment: environment,
    );
    expect(
      result.exitCode,
      0,
      reason:
          '$executable ${arguments.join(' ')}\n${result.stdout}\n${result.stderr}',
    );
    return result;
  }

  void expectProgramOutput(ProcessResult result) {
    expect(jsonDecode((result.stdout as String).trim()), {'answer': 42});
  }

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('sdk_files.');
    environment['HOME'] = work.path;
    environment['APPDATA'] = work.path;
    app = '${work.path}/app';
    void write(String path, String content) => (File(
      '$app/$path',
    )..createSync(recursive: true)).writeAsStringSync(content);
    write('pubspec.yaml', 'name: app\nenvironment:\n  sdk: ^3.0.0\n');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'app',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );
    write('lib/answer.dart', 'int answer() => 42;\n');
    write(
      'bin/main.dart',
      "import 'dart:convert';\n"
          "import 'dart:io';\n"
          "import 'package:app/answer.dart';\n"
          '\n'
          'void main() {\n'
          "  stdout.writeln(jsonEncode({'answer': answer()}));\n"
          '}\n',
    );
    write(
      'web/main.dart',
      "import 'dart:js_interop';\n"
          "import 'package:app/answer.dart';\n"
          '\n'
          "@JS('console.log')\n"
          'external void log(JSAny? value);\n'
          '\n'
          'void main() {\n'
          '  log(answer().toJS);\n'
          '}\n',
    );
    packages = '$app/.dart_tool/package_config.json';
    productKernel = '${work.path}/product.dill';
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  group('kernel', () {
    test('frontend_server compiles for the product runtime', () async {
      await run(tool('kernel', 'dartaotruntime'), [
        snapshot('kernel', 'frontend_server_aot.dart.snapshot'),
        '--sdk-root',
        '${sdk('kernel')}/lib/_internal/',
        '--platform',
        'vm_platform_product.dill',
        '-Ddart.vm.product=true',
        '--no-print-incremental-dependencies',
        '--packages',
        packages,
        '--output-dill',
        productKernel,
        'bin/main.dart',
      ]);
    });

    test('kernel_worker compiles a module', () async {
      // Exec paths, as Bazel gives them: `kernel_worker` reads a path as a
      // URI, so an absolute Windows one would read as a `c:` URI. The work
      // directory stands in for the exec root.
      const platform = 'sdk/lib/_internal/vm_platform_product.dill';
      const librariesSpec = 'sdk/lib/libraries.json';
      for (final path in [platform, librariesSpec]) {
        final to = File('${work.path}/$path');
        to.parent.createSync(recursive: true);
        File('${sdk('kernel')}/${path.substring('sdk/'.length)}')
            .copySync(to.path);
      }
      await run(tool('kernel', 'dartaotruntime'), [
        snapshot('kernel', 'kernel_worker_aot.dart.snapshot'),
        '--target',
        'vm',
        '--dart-sdk-summary',
        platform,
        '--libraries-file',
        librariesSpec,
        '--packages-file',
        'app/.dart_tool/package_config.json',
        '--no-summary-only',
        '--exclude-non-sources',
        '--source',
        'package:app/answer.dart',
        '--output',
        'module.dill',
      ], workingDirectory: work.path);
    });

    test('frontend_server compiles an entrypoint', () async {
      await run(tool('kernel', 'dartaotruntime'), [
        snapshot('kernel', 'frontend_server_aot.dart.snapshot'),
        '--sdk-root',
        '${sdk('kernel')}/lib/_internal/',
        '--platform',
        'vm_platform_product.dill',
        '--target',
        'vm',
        '--packages',
        packages,
        '--output-dill',
        '${work.path}/entry.dill',
        'bin/main.dart',
      ]);
    });
  });

  group('run', () {
    test('runs a kernel', () async {
      expectProgramOutput(
        await run(tool('run', 'dart'), ['--enable-asserts', productKernel]),
      );
    });

    test('runs a script', () async {
      expectProgramOutput(
        await run(tool('run', 'dart'), [
          '--packages=$packages',
          'bin/main.dart',
        ]),
      );
    });
  });

  test('aot_compile builds an exe and an AOT snapshot aot_run runs', () async {
    final binary = '${work.path}/main$exe';
    await run(tool('aot_compile', 'dart'), [
      'compile',
      'exe',
      '-o',
      binary,
      productKernel,
    ]);
    expectProgramOutput(await run(binary, []));

    final aot = '${work.path}/main.aot';
    await run(tool('aot_compile', 'dart'), [
      'compile',
      'aot-snapshot',
      '-o',
      aot,
      productKernel,
    ]);
    expectProgramOutput(await run(tool('aot_run', 'dartaotruntime'), [aot]));
  });

  test('format checks a file', () async {
    await run(tool('format', 'dart'), [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      '--language-version=latest',
      'lib/answer.dart',
    ]);
  });

  test('analyze analyzes a package', () async {
    await run(tool('analyze', 'dart'), ['analyze', '--fatal-infos', '.']);
  });

  test('analyze hosts the analysis server as the worker does', () async {
    await run(paths['analyze_runner']!, [
      '--host',
      paths['analysis_host']!,
      '--dart',
      tool('analyze', 'dart'),
      '--project',
      '.',
      '--stamp',
      '${work.path}/analyzed',
      '--fatal-infos',
    ]);
    expect(File('${work.path}/analyzed').existsSync(), isTrue);
  });

  test('codegen is what the analyzer reads of the SDK', () async {
    await run(paths['analyzer_errors']!, [sdk('codegen'), 'bin/main.dart']);
  });

  // Every flag combination `dart_js_binary` and `dart_wasm_binary` pass: the
  // compilation-mode defaults (`-c dbg` and `-c opt`) and the flags a target
  // commonly adds through `dart_compile_flags`. A flag can read a file the
  // default compile does not (`--server-mode` its own platform, `--dump-info`
  // and `-O4` their own passes), so each runs against the subset.
  const dart2jsFlags = {
    'default': <String>[],
    'dbg': ['--enable-asserts', '-O0'],
    'opt': ['-O2'],
    'O4': ['-O4'],
    'server-mode': ['--server-mode'],
    'dump-info': ['--dump-info'],
  };
  const dart2wasmFlags = {
    'default': <String>[],
    'dbg': ['--enable-asserts'],
    'O0': ['-O0'],
    'O4 without source maps': ['-O4', '--no-source-maps'],
    'no-strip-wasm': ['--no-strip-wasm'],
  };

  group('dart2js compiles to JavaScript', () {
    for (final MapEntry(key: name, value: flags) in dart2jsFlags.entries) {
      test(name, () async {
        final js = '${work.path}/main.js';
        await run(tool('dart2js', 'dart'), [
          'compile',
          'js',
          ...flags,
          '-o',
          js,
          'web/main.dart',
        ]);
        expect(File(js).existsSync(), isTrue);
      });
    }
  });

  group('dart2wasm compiles to WebAssembly', () {
    for (final MapEntry(key: name, value: flags) in dart2wasmFlags.entries) {
      test(name, () async {
        final wasm = '${work.path}/main.wasm';
        await run(tool('dart2wasm', 'dart'), [
          'compile',
          'wasm',
          ...flags,
          '-o',
          wasm,
          'web/main.dart',
        ]);
        expect(File(wasm).existsSync(), isTrue);
      });
    }
  });
}
