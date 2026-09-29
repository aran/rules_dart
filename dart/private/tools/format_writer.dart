// The executable behind `dart_format`: formats workspace files under `bazel run`
// with the options a `dart_format_test` would check them against.
//
// `dart format` cannot be pointed at an options file or a package config; it
// finds both by walking up from each file. So the files are copied into a
// scratch project whose root holds the rule's staged options file and a package
// config that resolves the ruleset packages in runfiles, formatted there, and
// copied back only when they changed.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _usage =
    'usage: bazel run <dart_format target> -- '
    '[--language-version=<major>.<minor>] <files or directories...>';

void main(List<String> args) {
  var languageVersion = 'latest';
  final operands = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--language-version') {
      if (++i >= args.length) _usageError('--language-version needs a value');
      languageVersion = args[i];
    } else if (arg.startsWith('--language-version=')) {
      languageVersion = arg.substring('--language-version='.length);
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln(_usage);
      return;
    } else if (arg.startsWith('-')) {
      _usageError('unknown option $arg');
    } else {
      operands.add(arg);
    }
  }
  if (operands.isEmpty) _usageError('name at least one file or directory');

  // Relative operands mean what they meant in the shell `bazel run` was typed
  // in. Without this there is no such directory, and resolving against the
  // runfiles cwd would format nothing the user named.
  final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
  if (cwd == null || cwd.isEmpty) {
    stderr.writeln(
      'dart_format: BUILD_WORKING_DIRECTORY is not set. Run this with '
      '`bazel run` on the target.',
    );
    exit(1);
  }

  final config = _readConfig();
  final files = <String, File>{};
  for (final operand in operands) {
    final path = _isAbsolute(operand)
        ? operand
        : '$cwd${Platform.pathSeparator}$operand';
    for (final file in _dartFiles(path)) {
      files.putIfAbsent(file.absolute.path, () => file);
    }
  }

  final scratch = Directory.systemTemp.createTempSync('dart_format.');
  final int code;
  try {
    code = _format(
      config,
      files.values.toList(),
      scratch,
      languageVersion,
      cwd,
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
  // Only after the scratch copy is gone: `exit` skips pending `finally` blocks.
  exit(code);
}

int _format(
  _Config config,
  List<File> files,
  Directory scratch,
  String languageVersion,
  String cwd,
) {
  File(
    _join(scratch.path, 'analysis_options.yaml'),
  ).writeAsBytesSync(File(config.options).readAsBytesSync());
  File(_join(scratch.path, '.dart_tool/package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(_absolutePackageConfig(config.packageConfig));

  // One directory per file keeps each basename, so the formatter's own
  // messages still name a recognisable file; the prefix is rewritten below.
  final src = _join(scratch.path, 'src');
  final copies = <File, File>{};
  for (final (i, file) in files.indexed) {
    final copy = File(_join(src, '$i/${_basename(file.path)}'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(file.readAsBytesSync());
    copies[file] = copy;
  }
  if (copies.isEmpty) {
    stdout.writeln('dart_format: no Dart files found');
    return 0;
  }

  final result = Process.runSync(
    config.dart,
    [
      'format',
      '--output=write',
      '--show=none',
      '--summary=none',
      '--language-version=$languageVersion',
      src,
    ],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  var err = result.stderr as String;
  var out = result.stdout as String;
  copies.forEach((file, copy) {
    err = err.replaceAll(copy.path, file.path);
    out = out.replaceAll(copy.path, file.path);
  });
  stdout.write(out);
  stderr.write(err);

  // An options file the formatter could not read is reported as a warning and
  // then ignored, which is exactly the silent rewrap this rule exists to
  // prevent. Writing nothing is the only safe answer to it.
  if (const LineSplitter().convert(err).any((l) => l.startsWith('Warning:'))) {
    stderr.writeln(
      'dart_format: `dart format` could not read the analysis options, so it '
      'would have formatted at stock defaults. Nothing was written.',
    );
    return 1;
  }

  // Files the formatter could not parse are left as they were; the rest are
  // written, as `dart format` itself does, and its exit code is kept.
  var changed = 0;
  copies.forEach((file, copy) {
    final before = file.readAsBytesSync();
    final after = copy.readAsBytesSync();
    if (_sameBytes(before, after)) return;
    // Bytes rather than File.copySync, which could carry the scratch copy's
    // mode onto the user's source file.
    file.writeAsBytesSync(after);
    changed++;
    stdout.writeln('Formatted ${_display(file.path, cwd)}');
  });
  final noun = copies.length == 1 ? 'file' : 'files';
  stdout.writeln('Formatted ${copies.length} $noun ($changed changed)');
  return result.exitCode;
}

class _Config {
  _Config(this.dart, this.options, this.packageConfig);

  final String dart;
  final String options;
  final String packageConfig;
}

_Config _readConfig() {
  final key = Platform.environment['DART_FORMAT_CONFIG'];
  if (key == null || key.isEmpty) {
    stderr.writeln('dart_format: DART_FORMAT_CONFIG is not set');
    exit(1);
  }
  final r = Runfiles.create();
  final json =
      jsonDecode(File(r.rlocation(key)).readAsStringSync())
          as Map<String, dynamic>;
  return _Config(
    r.rlocation(json['dart'] as String),
    r.rlocation(json['options'] as String),
    r.rlocation(json['package_config'] as String),
  );
}

/// The staged package config with every `rootUri` made absolute.
///
/// The staged roots are relative to where the config was staged; the scratch
/// copy lives elsewhere, so they are resolved against the original first.
String _absolutePackageConfig(String path) {
  final base = Uri.file(path);
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  for (final package in json['packages'] as List<dynamic>) {
    final entry = package as Map<String, dynamic>;
    entry['rootUri'] = base.resolve(entry['rootUri'] as String).toString();
  }
  return jsonEncode(json);
}

/// The `.dart` files [path] names, walked the way `dart format` walks a
/// directory: links are not followed and hidden directories are skipped.
Iterable<File> _dartFiles(String path) sync* {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.file) {
    yield File(path);
    return;
  }
  if (type != FileSystemEntityType.directory) {
    stderr.writeln('dart_format: no such file or directory: $path');
    exit(1);
  }
  final entries = Directory(path).listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    if (_basename(entry.path).startsWith('.')) continue;
    if (entry is Directory) {
      yield* _dartFiles(entry.path);
    } else if (entry is File && entry.path.endsWith('.dart')) {
      yield entry;
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

String _join(String base, String relative) =>
    [base, ...relative.split('/')].join(Platform.pathSeparator);

/// [path] relative to [cwd] when it is under it, as the user typed it.
String _display(String path, String cwd) {
  final prefix = '$cwd${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

Never _usageError(String message) {
  stderr.writeln('dart_format: $message');
  stderr.writeln(_usage);
  exit(64);
}
