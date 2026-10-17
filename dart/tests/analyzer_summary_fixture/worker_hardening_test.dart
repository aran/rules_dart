import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

Uint8List _encodeWorkRequest({
  required List<String> arguments,
  Map<String, Uint8List> inputs = const {},
  int requestId = 0,
}) {
  final body = BytesBuilder(copy: false);
  void writeVarint(BytesBuilder b, int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    b.addByte(v);
  }

  for (final arg in arguments) {
    final bytes = utf8.encode(arg);
    writeVarint(body, (1 << 3) | 2);
    writeVarint(body, bytes.length);
    body.add(bytes);
  }
  inputs.forEach((path, digest) {
    final pathBytes = utf8.encode(path);
    final nested = BytesBuilder(copy: false);
    writeVarint(nested, (1 << 3) | 2);
    writeVarint(nested, pathBytes.length);
    nested.add(pathBytes);
    if (digest.isNotEmpty) {
      writeVarint(nested, (2 << 3) | 2);
      writeVarint(nested, digest.length);
      nested.add(digest);
    }
    final nestedBytes = nested.takeBytes();
    writeVarint(body, (2 << 3) | 2);
    writeVarint(body, nestedBytes.length);
    body.add(nestedBytes);
  });
  if (requestId != 0) {
    writeVarint(body, (3 << 3) | 0);
    writeVarint(body, requestId);
  }
  final payload = body.takeBytes();
  final frame = BytesBuilder(copy: false);
  writeVarint(frame, payload.length);
  frame.add(payload);
  return frame.takeBytes();
}

Stream<Uint8List> _frameStream(Stream<List<int>> source) {
  final controller = StreamController<Uint8List>();
  var buf = Uint8List(0);
  source.listen(
    (chunk) {
      final merged = Uint8List(buf.length + chunk.length);
      merged.setRange(0, buf.length, buf);
      merged.setRange(buf.length, merged.length, chunk);
      buf = merged;
      while (true) {
        var len = 0;
        var shift = 0;
        var pos = 0;
        while (true) {
          if (pos >= buf.length) return;
          final b = buf[pos++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (buf.length < pos + len) return;
        controller.add(Uint8List.sublistView(buf, pos, pos + len));
        buf = Uint8List.sublistView(buf, pos + len);
      }
    },
    onError: controller.addError,
    onDone: controller.close,
  );
  return controller.stream;
}

({int exitCode, String output}) _decodeWorkResponse(Uint8List payload) {
  var pos = 0;
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = payload[pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  var exitCode = 0;
  var output = '';
  while (pos < payload.length) {
    final tag = readVarint();
    switch (tag >> 3) {
      case 1:
        exitCode = readVarint();
      case 2:
        final len = readVarint();
        output = utf8.decode(Uint8List.sublistView(payload, pos, pos + len));
        pos += len;
      case 3:
        readVarint();
      default:
        throw StateError('Unexpected wire tag: $tag');
    }
  }
  return (exitCode: exitCode, output: output);
}

void main(List<String> args) {
  final r = Runfiles.create();
  final formatRunnerDill = r.rlocation(args[0]);
  final analyzerSummaryDill = r.rlocation(args[1]);
  final sdkSummaryPath = r.rlocation(args[2]);
  final sdkRoot = File(Platform.resolvedExecutable).parent.parent.path;

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('worker_hardening_test.');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test(
    'analyzer_summary and format_runner are compiled in kernel (.dill) mode',
    () {
      expect(formatRunnerDill, endsWith('.dill'));
      expect(analyzerSummaryDill, endsWith('.dill'));
      expect(File(formatRunnerDill).existsSync(), isTrue);
      expect(File(analyzerSummaryDill).existsSync(), isTrue);
    },
  );

  test('analyzer_summary worker invalidates empty digests and prunes orphaned symlinks', () async {
    Directory('${tmp.path}/pkg_dep/lib').createSync(recursive: true);
    Directory('${tmp.path}/pkg_main/src/lib').createSync(recursive: true);
    Directory('${tmp.path}/pkg_main/.dart_tool').createSync(recursive: true);

    File('${tmp.path}/pkg_dep_packages.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'pkg_dep',
            'rootUri': 'pkg_dep',
            'packageUri': 'lib/',
            'languageVersion': '3.7',
          },
        ],
      }),
    );
    File('${tmp.path}/pkg_main/src/pubspec.yaml')
        .writeAsStringSync('name: pkg_main\nenvironment:\n  sdk: ^3.7.0\n');
    File('${tmp.path}/pkg_main/.dart_tool/package_config.json')
        .writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'pkg_dep',
                'rootUri': '../../pkg_dep',
                'packageUri': 'lib/',
                'languageVersion': '3.7',
              },
              {
                'name': 'pkg_main',
                'rootUri': '../src',
                'packageUri': 'lib/',
                'languageVersion': '3.7',
              },
            ],
          }),
        );

    File('${tmp.path}/pkg_dep/lib/dep.dart')
        .writeAsStringSync('int foo() => 1;\n');
    File('${tmp.path}/pkg_main/src/lib/main.dart').writeAsStringSync(
      "import 'package:pkg_dep/dep.dart';\nint callBar() => bar();\n",
    );

    final proc = await Process.start(Platform.resolvedExecutable, [
      analyzerSummaryDill,
      '--persistent_worker',
    ], workingDirectory: tmp.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));

    Future<({int exitCode, String output})> send(
      List<String> arguments, {
      Map<String, Uint8List> inputs = const {},
    }) async {
      proc.stdin.add(_encodeWorkRequest(arguments: arguments, inputs: inputs));
      await proc.stdin.flush();
      expect(await responses.moveNext(), isTrue);
      return _decodeWorkResponse(responses.current);
    }

    // 1. Summarize V1 of pkg_dep (without bar())
    var res = await send([
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'pkg_dep_packages.json',
      '--out',
      'dep.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'pkg_dep/lib/dep.dart',
      '--uri',
      'package:pkg_dep/dep.dart',
    ]);
    expect(res.exitCode, 0, reason: res.output);

    // 2. Analyze pkg_main with an empty digest in WorkRequest.inputs -> fails
    res = await send(
      [
        'analyze',
        '--sdk',
        sdkRoot,
        '--project',
        'pkg_main',
        '--stamp',
        'analyzed.stamp',
        '--sdk-summary',
        sdkSummaryPath,
        '--summary',
        'dep.sum',
      ],
      inputs: {'dep.sum': Uint8List(0)},
    );
    expect(res.exitCode, 1);

    // 3. Update pkg_dep to V2 (adding bar()), re-summarize, and re-analyze
    // with empty digest -> must re-stat and pass (exit 0)
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${tmp.path}/pkg_dep/lib/dep.dart').writeAsStringSync(
      'int foo() => 1;\nint bar() => 2;\nString extra() => "v2";\n',
    );
    res = await send([
      'summarize',
      '--sdk',
      sdkRoot,
      '--packages',
      'pkg_dep_packages.json',
      '--out',
      'dep.sum',
      '--sdk-summary',
      sdkSummaryPath,
      '--source',
      'pkg_dep/lib/dep.dart',
      '--uri',
      'package:pkg_dep/dep.dart',
    ]);
    expect(res.exitCode, 0, reason: res.output);

    res = await send(
      [
        'analyze',
        '--sdk',
        sdkRoot,
        '--project',
        'pkg_main',
        '--stamp',
        'analyzed.stamp',
        '--sdk-summary',
        sdkSummaryPath,
        '--summary',
        'dep.sum',
      ],
      inputs: {'dep.sum': Uint8List(0)},
    );
    expect(res.exitCode, 0, reason: res.output);

    // 4. Plant an orphaned symlink in pkg_main/src/lib/removed_bad.dart
    File('${tmp.path}/real_removed_bad.dart')
        .writeAsStringSync("int broken = 'not_an_int';\n");
    Link('${tmp.path}/pkg_main/src/lib/removed_bad.dart')
        .createSync('${tmp.path}/real_removed_bad.dart');
    File('${tmp.path}/pkg_main/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pubspec.yaml\nlib/main.dart\n');

    res = await send([
      'analyze',
      '--sdk',
      sdkRoot,
      '--project',
      'pkg_main',
      '--stamp',
      'analyzed2.stamp',
      '--sdk-summary',
      sdkSummaryPath,
      '--summary',
      'dep.sum',
    ]);
    expect(res.exitCode, 0, reason: res.output);
    expect(
      FileSystemEntity.typeSync(
        '${tmp.path}/pkg_main/src/lib/removed_bad.dart',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    await responses.cancel();
    await proc.stdin.close();
  });

  test('format_runner does not escape <project>/src into execroot analysis_options.yaml', () async {
    final execroot = Directory('${tmp.path}/execroot')
      ..createSync(recursive: true);
    File('${execroot.path}/analysis_options.yaml').writeAsStringSync(
      'include: package:nonexistent_lints/lints.yaml\n'
      'formatter:\n'
      '  page_width: 40\n',
    );

    final projDir = Directory(
      '${execroot.path}/bazel-out/k8-fastbuild/bin/pkg/target.format.proj',
    );
    Directory('${projDir.path}/src/pkg/lib').createSync(recursive: true);
    Directory('${projDir.path}/.dart_tool').createSync(recursive: true);
    File('${projDir.path}/.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': <Object?>[]}),
    );
    File('${projDir.path}/src/pkg/lib/clean.dart').writeAsStringSync(
      "void main() {\n  print('hello world from a 60-char line that fits in 80');\n}\n",
    );
    File('${projDir.path}/.dart_tool/src_manifest.txt')
        .writeAsStringSync('pkg/lib/clean.dart\n');
    Link('${projDir.path}/src/analysis_options.yaml')
        .createSync('${execroot.path}/analysis_options.yaml');

    File('${execroot.path}/manifest.txt')
        .writeAsStringSync('src/pkg/lib/clean.dart\n');

    final proc = await Process.start(Platform.resolvedExecutable, [
      formatRunnerDill,
      '--persistent_worker',
    ], workingDirectory: execroot.path);
    addTearDown(proc.kill);
    final responses = StreamIterator(_frameStream(proc.stdout));

    proc.stdin.add(
      _encodeWorkRequest(
        arguments: [
          '--project',
          'bazel-out/k8-fastbuild/bin/pkg/target.format.proj',
          '--manifest',
          'manifest.txt',
          '--stamp',
          'formatted.stamp',
          '--language-version',
          'latest',
        ],
      ),
    );
    await proc.stdin.flush();
    expect(await responses.moveNext(), isTrue);
    final resp = _decodeWorkResponse(responses.current);
    expect(resp.exitCode, 0, reason: resp.output);
    expect(resp.output, isEmpty);
    expect(
      FileSystemEntity.typeSync(
        '${projDir.path}/src/analysis_options.yaml',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );

    await responses.cancel();
    await proc.stdin.close();
  });
}
