// Build-action runner for the `dart_analyze` aspect's format check: `dart format`
// over a staged project directory.
//
// `dart format` produces no output artifact, but a Bazel action must; this
// runner forwards the formatter's diagnostics and writes the stamp file only
// on success. Pure Dart (no shell) so the action is portable to Windows.
//
// Files are named individually from a manifest rather than by handing the
// formatter the project directory. The staged project also holds the harness
// (stub pubspecs, package_config.json), the target's dependencies and any lint
// ruleset an options file pulls in — none of which are the target's to format.
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout, running
// `package:dart_style` in-process when the target's language version is
// supported and falling back to the SDK's `dart format` CLI otherwise.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_style/dart_style.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/analysis_options_file.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/file_system.dart';
// ignore: implementation_imports
import 'package:dart_style/src/analysis_options/io_file_system.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const _argvBudget = 8000;

List<String> _expandParamFiles(List<String> args) {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      out.addAll(File(arg.substring(1)).readAsLinesSync());
    } else {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> rawArgs) async {
  final args = _expandParamFiles(rawArgs);
  if (args.contains('--persistent_worker')) {
    await _runPersistentWorker();
    return;
  }
  final code = await _runSingleRequest(args, outSink: stdout, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = _expandParamFiles(request.arguments);
      code = await _runSingleRequest(
        expanded,
        outSink: output,
        errSink: output,
      );
    } on Object catch (e, st) {
      output
        ..writeln('format_runner: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      _WorkResponse(
        exitCode: code,
        output: output.toString(),
        requestId: request.requestId,
      ).write(),
    );
    await stdout.flush();
  }
}

Future<int> _runSingleRequest(
  List<String> args, {
  required StringSink outSink,
  required StringSink errSink,
}) async {
  String? dart;
  String? project;
  String? manifest;
  String? stamp;
  String? languageVersion;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.isEmpty) continue;
    switch (arg) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--language-version':
        languageVersion = args[++i];
      default:
        errSink.writeln('format_runner: unknown argument $arg');
        return 64;
    }
  }
  if (project == null ||
      manifest == null ||
      stamp == null ||
      languageVersion == null) {
    errSink.writeln(
      'format_runner: --project, --manifest, --stamp, and '
      '--language-version are required',
    );
    return 64;
  }

  _pruneOrphanedStagedFiles(project);

  final files = File(manifest)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .map((l) => _join(project!, l))
      .toList();

  final parsedVersion = _parseLanguageVersion(languageVersion);
  if (parsedVersion == null) {
    if (dart != null) {
      return _runSubprocessFallback(
        dart: dart,
        project: project,
        files: files,
        languageVersion: languageVersion,
        stamp: stamp,
        outSink: outSink,
        errSink: errSink,
      );
    }
    errSink.writeln(
      'format_runner: unsupported --language-version "$languageVersion"',
    );
    return 64;
  }

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final projectRoot = p.normalize(p.absolute(project));
  final srcRoot = p.normalize(p.join(projectRoot, 'src'));
  final fileSystem = _BoundedFileSystem(
    IOFileSystem(),
    srcRoot: srcRoot,
    projectRoot: projectRoot,
  );
  final directoryConfigs = <String, PackageConfig?>{};
  final directoryOptions =
      <String, ({int? pageWidth, TrailingCommas? trailingCommas})>{};
  final failedReadPaths = <String>{};

  Future<PackageConfig?> findDirPackageConfig(File file) async {
    final dir = file.parent.path;
    if (directoryConfigs.containsKey(dir)) {
      return directoryConfigs[dir];
    }
    try {
      var current = Directory(p.normalize(p.absolute(dir)));
      while (true) {
        final cfg = await findPackageConfig(current, recurse: false);
        if (cfg != null) {
          return directoryConfigs[dir] = cfg;
        }
        final normCurrent = p.normalize(current.path);
        if (normCurrent == projectRoot) break;
        final parent = current.parent;
        if (p.normalize(parent.path) == normCurrent) break;
        current = parent;
      }
      return directoryConfigs[dir] = null;
    } on Object {
      return directoryConfigs[dir] = null;
    }
  }

  Future<String?> resolvePackageUri(File file, Uri packageUri) async {
    final config = await findDirPackageConfig(file);
    if (config == null) return null;
    return config.resolve(packageUri)?.toFilePath();
  }

  void reportFailedRead(String path) {
    if (failedReadPaths.add(path)) {
      errBuf.writeln('Warning: Couldn\'t read file "$path".');
    }
  }

  Future<({int? pageWidth, TrailingCommas? trailingCommas})> findOptions(
    File file,
  ) async {
    final dir = file.parent.path;
    if (directoryOptions[dir] case final cached?) return cached;
    int? pageWidth;
    TrailingCommas? trailingCommas;
    try {
      final optionsFile = await findAnalysisOptions(
        fileSystem,
        await fileSystem.makePath(file.path),
        reportFailedRead: reportFailedRead,
        resolvePackageUri: (uri) => resolvePackageUri(file, uri),
      );
      if (optionsFile['formatter'] case Map<Object?, Object?> formatter) {
        if (formatter case {'page_width': int width}) {
          pageWidth = width;
        }
        if (formatter case {'trailing_commas': var commas}) {
          switch (commas) {
            case 'automate':
              trailingCommas = TrailingCommas.automate;
            case 'preserve':
              trailingCommas = TrailingCommas.preserve;
            default:
              errBuf.writeln(
                'Warning: "trailing_commas" option should be "automate" or '
                '"preserve", but was "$commas".',
              );
          }
        }
      }
    } on PackageResolutionException catch (exception) {
      errBuf.writeln(
        'Warning: Package resolution error when reading '
        '"analysis_options.yaml" file for "${file.path}":\n$exception',
      );
    }
    return directoryOptions[dir] = (
      pageWidth: pageWidth,
      trailingCommas: trailingCommas,
    );
  }

  final stopwatch = Stopwatch()..start();
  var changedCount = 0;
  var hadError = false;

  for (final path in files) {
    final file = File(path);
    if (!file.existsSync()) {
      errBuf.writeln('No file or directory found at "$path".');
      hadError = true;
      continue;
    }
    final opts = await findOptions(file);
    final formatter = DartFormatter(
      languageVersion: parsedVersion,
      pageWidth: opts.pageWidth ?? DartFormatter.defaultPageWidth,
      trailingCommas: opts.trailingCommas,
    );
    try {
      final source = SourceCode(file.readAsStringSync(), uri: file.path);
      final output = formatter.formatSource(source);
      final changed = source.text != output.text;
      if (changed) {
        outBuf.writeln('Changed ${file.path}');
        changedCount++;
      }
    } on FormatterException catch (err) {
      errBuf.writeln(err.message(color: false));
      hadError = true;
    } on UnexpectedOutputException catch (err) {
      errBuf.writeln('''Hit a bug in the formatter when formatting ${file.path}.
$err
Please report at github.com/dart-lang/dart_style/issues.''');
      hadError = true;
    } on Object catch (err, stack) {
      errBuf.writeln('''Hit a bug in the formatter when formatting ${file.path}.
Please report at github.com/dart-lang/dart_style/issues.
$err
$stack''');
      hadError = true;
    }
  }

  stopwatch.stop();
  final time = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2);
  if (files.isEmpty) {
    outBuf.writeln('Formatted no files in $time seconds.');
  } else if (files.length == 1) {
    outBuf.writeln(
      'Formatted 1 file ($changedCount changed) in $time seconds.',
    );
  } else {
    outBuf.writeln(
      'Formatted ${files.length} files ($changedCount changed) in $time seconds.',
    );
  }

  var failed = false;
  final errStr = errBuf.toString();
  final outStr = outBuf.toString();
  errSink.write(_unstage(errStr, project));
  if (changedCount > 0 || hadError) {
    outSink.write(_unstage(outStr, project));
    failed = true;
  }
  if (_warned(errStr)) {
    errSink.writeln(
      'format_runner: `dart format` warned while reading analysis options, '
      'so the check would have run at stock defaults rather than the '
      'configured ones. Fix the options file named above.',
    );
    failed = true;
  }

  if (failed) {
    return 1;
  }
  File(stamp).writeAsStringSync('formatted\n');
  return 0;
}

Version? _parseLanguageVersion(String version) {
  if (version == 'latest') {
    return DartFormatter.latestLanguageVersion;
  }
  final match = RegExp(r'^([0-9]+)\.([0-9]+)$').firstMatch(version);
  if (match == null) return null;
  final parsed = Version(int.parse(match[1]!), int.parse(match[2]!), 0);
  if (parsed > DartFormatter.latestLanguageVersion ||
      parsed < Version(2, 12, 0)) {
    return null;
  }
  return parsed;
}

int _runSubprocessFallback({
  required String dart,
  required String project,
  required List<String> files,
  required String languageVersion,
  required String stamp,
  required StringSink outSink,
  required StringSink errSink,
}) {
  var failed = false;
  for (final chunk in _chunks(files)) {
    final result = Process.runSync(
      dart,
      [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        '--language-version=$languageVersion',
        ...chunk,
      ],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    errSink.write(_unstage(result.stderr as String, project));
    if (result.exitCode != 0) {
      outSink.write(_unstage(result.stdout as String, project));
      failed = true;
    }
    if (_warned(result.stderr as String)) {
      errSink.writeln(
        'format_runner: `dart format` warned while reading analysis options, '
        'so the check would have run at stock defaults rather than the '
        'configured ones. Fix the options file named above.',
      );
      failed = true;
    }
  }
  if (failed) return 1;
  File(stamp).writeAsStringSync('formatted\n');
  return 0;
}

void _pruneOrphanedStagedFiles(String project) {
  final srcDir = Directory(p.join(project, 'src'));
  if (!srcDir.existsSync()) return;
  final manifestFile = File(p.join(project, '.dart_tool', 'src_manifest.txt'));
  if (!manifestFile.existsSync()) return;
  final allowedPaths = <String>{
    for (final line in manifestFile.readAsLinesSync())
      if (line.isNotEmpty) p.normalize(p.absolute(p.join(srcDir.path, line))),
  };
  for (final entity in srcDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) continue;
    final normPath = p.normalize(entity.absolute.path);
    if (!allowedPaths.contains(normPath)) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Ignore if read-only or already removed.
      }
    }
  }
}

/// Wraps [IOFileSystem] so upward directory walks for `analysis_options.yaml`
/// stop at `<project>/src` (or `<project>`) and never escape into the shared
/// Bazel execroot or host filesystem.
final class _BoundedFileSystem implements FileSystem {
  const _BoundedFileSystem(
    this._delegate, {
    required this.srcRoot,
    required this.projectRoot,
  });

  final IOFileSystem _delegate;
  final String srcRoot;
  final String projectRoot;

  Future<IOFileSystemPath> makePath(String path) => _delegate.makePath(path);

  @override
  Future<bool> fileExists(covariant IOFileSystemPath path) =>
      _delegate.fileExists(path);

  @override
  Future<FileSystemPath> join(covariant IOFileSystemPath from, String to) =>
      _delegate.join(from, to);

  @override
  Future<FileSystemPath?> parentDirectory(
    covariant IOFileSystemPath path,
  ) async {
    final norm = p.normalize(p.absolute(path.path));
    if (norm == srcRoot || norm == projectRoot) {
      return null;
    }
    return _delegate.parentDirectory(path);
  }

  @override
  Future<String> readFile(covariant IOFileSystemPath path) =>
      _delegate.readFile(path);
}

String _unstage(String out, String project) {
  final relative = project.replaceAll(r'\', '/');
  final absolute = Directory(project).absolute.path.replaceAll(r'\', '/');
  final normalized = p.normalize(p.absolute(project)).replaceAll(r'\', '/');
  return out
      .replaceAll('$normalized/src/', '')
      .replaceAll('$absolute/src/', '')
      .replaceAll('$relative/src/', '');
}

bool _warned(String err) =>
    const LineSplitter().convert(err).any((l) => l.startsWith('Warning:'));

Iterable<List<String>> _chunks(List<String> files) sync* {
  var current = <String>[];
  var length = 0;
  for (final f in files) {
    if (current.isNotEmpty && length + f.length + 1 > _argvBudget) {
      yield current;
      current = <String>[];
      length = 0;
    }
    current.add(f);
    length += f.length + 1;
  }
  if (current.isNotEmpty) {
    yield current;
  }
}

String _join(String project, String relative) =>
    '${project.replaceAll(r'\', '/')}/$relative';

final class _WorkRequest {
  _WorkRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  factory _WorkRequest.read(Uint8List bytes) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = _Reader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = Uint8List(0);
          while (!nested.isDone) {
            final inputTag = nested.varint();
            switch (inputTag >> 3) {
              case 1:
                path = nested.string();
              case 2:
                digest = nested.bytes();
              default:
                nested.skip(inputTag & 7);
            }
          }
          if (path.isNotEmpty) {
            inputs[path] = digest;
          }
        case 3:
          requestId = r.varint();
        case 4:
          cancel = r.varint() != 0;
        default:
          r.skip(tag & 7);
      }
    }
    return _WorkRequest(
      arguments: arguments,
      inputs: inputs,
      requestId: requestId,
      cancel: cancel,
    );
  }

  final List<String> arguments;
  final Map<String, Uint8List> inputs;
  final int requestId;
  final bool cancel;
}

final class _WorkResponse {
  const _WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Uint8List write() {
    final body = _Writer();
    if (exitCode != 0) {
      body
        ..varint((1 << 3) | 0)
        ..varint(exitCode);
    }
    if (output.isNotEmpty) {
      final utf8Bytes = utf8.encode(output);
      body
        ..varint((2 << 3) | 2)
        ..varint(utf8Bytes.length)
        ..raw(utf8Bytes);
    }
    if (requestId != 0) {
      body
        ..varint((3 << 3) | 0)
        ..varint(requestId);
    }
    final payload = body.takeBytes();
    final frame = _Writer()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

final class _Frames extends Stream<Uint8List> {
  _Frames(this._source);

  final Stream<List<int>> _source;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    var buf = Uint8List(0);
    late final StreamSubscription<List<int>> sub;
    sub = _source.listen(
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
      cancelOnError: cancelOnError,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _Reader {
  _Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isDone => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final len = varint();
    final slice = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String string() => utf8.decode(bytes());

  _Reader submessage() => _Reader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        _pos += varint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

final class _Writer {
  final _buf = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      _buf.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _buf.addByte(v);
  }

  void raw(List<int> bytes) => _buf.add(bytes);

  Uint8List takeBytes() => _buf.takeBytes();
}
