// Links an executable's kernel from the kernels its entry reaches, or a shared
// base kernel from `--seed-module` directories. Run by `kernel_link_action` in
// `dart/private/dart_kernel.bzl`.
//
// The arguments are a params file holding optional flags (`--write-keys <path>`,
// `--base-keys <path>`, repeatable `--seed-module <dir>`), `<output>`, the entry
// module's directory (when `--seed-module` is not used), and then each dependency
// module's directory, one per line. Each directory holds an `index.json` that
// lists its kernels: the file of each, the keys of the libraries it defines, and
// the keys it imports. The entry's index names the entry kernel and what the
// entry imports.
//
// The link walks the imports from the entry (or seed modules), and writes only
// the kernels it reaches. The entry kernel comes first, then each dependency
// kernel after every kernel it imports. When `--base-keys <path>` is passed, any
// dependency kernel whose `<dir>:<dill>` key is already in the base kernel is
// skipped from the output (while still traversed during reachability so
// transitive imports through base modules are discovered).
//
// The entry comes first because the VM runs the `main` of the first component that
// has one, and a dependency's component can have a `main` of its own: a library that
// defines `main` for its CLI, say. Linking the entry last ran that library's `main`
// instead of the test's, and the test hung. With the entry first the test's `main` runs.
//
// The VM loads a file of concatenated kernels as one program. This is a compiled
// `dart_binary` of the exec platform, so the link runs without the SDK as an input,
// and a `dart_test` can name it as an executable attribute.
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout, caching
// parsed `index.json` manifests, `--base-keys` sets, and `.dill` bytes across
// requests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A kernel an index lists: its file, its `<dir>:<dill>` key, and what it defines and imports.
class _Kernel {
  _Kernel(this.path, this.key, this.defines, this.imports);

  final String path;
  final String key;
  final List<String> defines;
  final List<String> imports;
}

class _CachedEntry<T> {
  _CachedEntry(this.value, this.digest, this.rawBytes);

  final T value;
  final Uint8List? digest;
  final Uint8List rawBytes;
}

String _normalizePath(String path) {
  if (path.isEmpty) return '.';
  final isAbs = path.startsWith('/');
  final parts = path.split('/');
  final stack = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isNotEmpty && stack.last != '..') {
        stack.removeLast();
      } else if (!isAbs) {
        stack.add('..');
      }
    } else {
      stack.add(part);
    }
  }
  if (stack.isEmpty) return isAbs ? '/' : '.';
  final joined = stack.join('/');
  return isAbs ? '/$joined' : joined;
}

class KernelLinkCache {
  final _indexCache = <String, _CachedEntry<List<_Kernel>>>{};
  final _baseKeysCache = <String, _CachedEntry<Set<String>>>{};
  final _dillCache = <String, _CachedEntry<Uint8List>>{};
  int _dillBytesTotal = 0;
  static const int _maxDillCacheBytes = 128 * 1024 * 1024;
  static const int _maxIndexEntries = 4096;
  static const int _maxBaseKeysEntries = 256;

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List? _lookupExactOrNormalized(
    String path,
    Map<String, Uint8List> inputs,
  ) {
    final direct = inputs[path];
    if (direct != null && direct.isNotEmpty) return direct;
    final norm = _normalizePath(path);
    if (norm != path) {
      final normHit = inputs[norm];
      if (normHit != null && normHit.isNotEmpty) return normHit;
    }
    if (!norm.startsWith('/')) {
      final dotHit = inputs['./$norm'];
      if (dotHit != null && dotHit.isNotEmpty) return dotHit;
    }
    return null;
  }

  static Uint8List? _lookupDigest(String path, Map<String, Uint8List>? inputs) {
    if (inputs == null) return null;
    final direct = _lookupExactOrNormalized(path, inputs);
    if (direct != null) return direct;
    final norm = _normalizePath(path);
    final slash = norm.lastIndexOf('/');
    if (slash > 0) {
      final parent = _lookupExactOrNormalized(norm.substring(0, slash), inputs);
      if (parent != null) return parent;
    }
    return null;
  }

  List<_Kernel> kernelsOf(String dir, Map<String, Uint8List>? inputs) {
    final indexPath = '$dir/index.json';
    final digest = _lookupDigest(indexPath, inputs);
    final cached = _indexCache.remove(dir);
    if (cached != null &&
        digest != null &&
        digest.isNotEmpty &&
        cached.digest != null &&
        cached.digest!.isNotEmpty &&
        _sameBytes(digest, cached.digest!)) {
      _indexCache[dir] = cached;
      return cached.value;
    }
    final bytes = File(indexPath).readAsBytesSync();
    if (cached != null && _sameBytes(bytes, cached.rawBytes)) {
      _indexCache[dir] = _CachedEntry(
        cached.value,
        (digest != null && digest.isNotEmpty) ? digest : cached.digest,
        cached.rawBytes,
      );
      return cached.value;
    }
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final kernels = [
      for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
        _Kernel(
          '$dir/${scc['dill']}',
          '$dir:${scc['dill']}',
          (scc['defines'] as List).cast<String>(),
          (scc['imports'] as List).cast<String>(),
        ),
    ];
    while (_indexCache.length >= _maxIndexEntries && _indexCache.isNotEmpty) {
      _indexCache.remove(_indexCache.keys.first);
    }
    _indexCache[dir] = _CachedEntry(
      kernels,
      (digest != null && digest.isNotEmpty) ? digest : null,
      bytes,
    );
    return kernels;
  }

  Set<String> baseKeysOf(String path, Map<String, Uint8List>? inputs) {
    final key = _normalizePath(path);
    final digest = _lookupDigest(path, inputs);
    final cached = _baseKeysCache.remove(key);
    if (cached != null &&
        digest != null &&
        digest.isNotEmpty &&
        cached.digest != null &&
        cached.digest!.isNotEmpty &&
        _sameBytes(digest, cached.digest!)) {
      _baseKeysCache[key] = cached;
      return cached.value;
    }
    final bytes = File(path).readAsBytesSync();
    if (cached != null && _sameBytes(bytes, cached.rawBytes)) {
      _baseKeysCache[key] = _CachedEntry(
        cached.value,
        (digest != null && digest.isNotEmpty) ? digest : cached.digest,
        cached.rawBytes,
      );
      return cached.value;
    }
    final keys = <String>{};
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) keys.add(trimmed);
    }
    while (_baseKeysCache.length >= _maxBaseKeysEntries &&
        _baseKeysCache.isNotEmpty) {
      _baseKeysCache.remove(_baseKeysCache.keys.first);
    }
    _baseKeysCache[key] = _CachedEntry(
      keys,
      (digest != null && digest.isNotEmpty) ? digest : null,
      bytes,
    );
    return keys;
  }

  Uint8List dillBytesOf(String path, Map<String, Uint8List>? inputs) {
    final key = _normalizePath(path);
    final digest = _lookupDigest(path, inputs);
    final cached = _dillCache.remove(key);
    if (cached != null) {
      if (digest != null &&
          digest.isNotEmpty &&
          cached.digest != null &&
          cached.digest!.isNotEmpty &&
          _sameBytes(digest, cached.digest!)) {
        _dillCache[key] = cached;
        return cached.value;
      }
      _dillBytesTotal -= cached.value.length;
    }
    final bytes = File(path).readAsBytesSync();
    if (cached != null && _sameBytes(bytes, cached.value)) {
      final reused = _CachedEntry(
        cached.value,
        (digest != null && digest.isNotEmpty) ? digest : cached.digest,
        cached.value,
      );
      _dillCache[key] = reused;
      _dillBytesTotal += cached.value.length;
      return cached.value;
    }
    if (bytes.length <= 16 * 1024 * 1024) {
      while (_dillBytesTotal + bytes.length > _maxDillCacheBytes &&
          _dillCache.isNotEmpty) {
        final oldestKey = _dillCache.keys.first;
        final removed = _dillCache.remove(oldestKey)!;
        _dillBytesTotal -= removed.value.length;
      }
      _dillCache[key] = _CachedEntry(
        bytes,
        (digest != null && digest.isNotEmpty) ? digest : null,
        bytes,
      );
      _dillBytesTotal += bytes.length;
    }
    return bytes;
  }
}

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

Future<void> main(List<String> args) async {
  final expanded = _expandParamFiles(args);
  if (expanded.contains('--persistent_worker')) {
    await _runPersistentWorker();
    return;
  }
  final cache = KernelLinkCache();
  final code = linkOne(expanded, cache: cache, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  final cache = KernelLinkCache();
  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = _expandParamFiles(request.arguments);
      code = linkOne(
        expanded,
        cache: cache,
        inputs: request.inputs,
        errSink: output,
      );
    } on Object catch (e, st) {
      output
        ..writeln('kernel_link: unhandled exception: $e')
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

int linkOne(
  List<String> rawArgs, {
  required KernelLinkCache cache,
  Map<String, Uint8List>? inputs,
  required StringSink errSink,
}) {
  String? writeKeysPath;
  String? baseKeysPath;
  String? platform;
  final seedModules = <String>[];
  final paths = <String>[];
  for (var i = 0; i < rawArgs.length; i++) {
    final arg = rawArgs[i];
    if (arg.isEmpty) continue;
    if (arg == '--write-keys') {
      writeKeysPath = rawArgs[++i];
    } else if (arg == '--base-keys') {
      baseKeysPath = rawArgs[++i];
    } else if (arg == '--seed-module') {
      seedModules.add(rawArgs[++i]);
    } else if (arg == '--platform' && i + 1 < rawArgs.length) {
      platform = rawArgs[++i];
    } else if (arg.startsWith('--platform=')) {
      platform = arg.substring('--platform='.length);
    } else {
      paths.add(arg);
    }
  }
  final output = paths[0];
  final _Kernel? entry;
  final Iterable<String> depDirs;
  if (seedModules.isEmpty) {
    entry = cache.kernelsOf(paths[1], inputs).single;
    depDirs = paths.skip(2);
  } else {
    entry = null;
    depDirs = paths.skip(1);
  }

  final owner = <String, _Kernel>{};
  final kernelsByDir = <String, List<_Kernel>>{};
  for (final dir in <String>{...seedModules, ...depDirs}) {
    final kernels = cache.kernelsOf(dir, inputs);
    kernelsByDir[dir] = kernels;
    for (final kernel in kernels) {
      for (final key in kernel.defines) {
        owner.putIfAbsent(key, () => kernel);
      }
    }
  }

  final baseKeys = baseKeysPath != null
      ? cache.baseKeysOf(baseKeysPath, inputs)
      : const <String>{};

  final order = <_Kernel>[];
  final visited = <_Kernel>{};
  var missingModule = false;
  void visit(_Kernel kernel) {
    if (baseKeys.contains(kernel.key) || !visited.add(kernel)) return;
    for (final key in ([...kernel.imports]..sort())) {
      if (baseKeys.contains(key)) continue;
      final dependency = owner[key];
      if (dependency != null) {
        visit(dependency);
      } else if (!key.startsWith('dart:')) {
        errSink.writeln(
          'kernel_link: missing module for imported library $key (imported by ${kernel.path})',
        );
        missingModule = true;
      }
    }
    order.add(kernel);
  }

  if (entry != null) {
    for (final key in ([...entry.imports]..sort())) {
      if (baseKeys.contains(key)) continue;
      final dependency = owner[key];
      if (dependency != null) {
        visit(dependency);
      } else if (!key.startsWith('dart:')) {
        errSink.writeln(
          'kernel_link: missing module for imported library $key (imported by ${entry.path})',
        );
        missingModule = true;
      }
    }
  } else {
    for (final seedDir in seedModules) {
      final kernels = kernelsByDir[seedDir]!;
      final isPackageTest = kernels.any(
        (k) => k.defines.any((d) => d.endsWith('/lib/bootstrap/vm.dart')),
      );
      for (final kernel in kernels) {
        if (isPackageTest) {
          final isTestApi = kernel.defines.any(
            (d) =>
                d.endsWith('/lib/test.dart') ||
                d.endsWith('/lib/scaffolding.dart') ||
                d.endsWith('/lib/expect.dart') ||
                d.endsWith('/lib/bootstrap/vm.dart') ||
                d.endsWith('/lib/fake.dart'),
          );
          if (!isTestApi) continue;
        }
        visit(kernel);
      }
    }
  }
  if (missingModule) return 1;

  final linked = [if (entry != null) entry, ...order];
  final definedBy = <String, _Kernel>{};
  for (final kernel in linked) {
    for (final key in kernel.defines) {
      final other = definedBy[key];
      if (other != null) {
        errSink.writeln(
          'kernel_link: $key is defined by ${other.path} and ${kernel.path}.',
        );
        return 1;
      }
      definedBy[key] = kernel;
    }
  }

  final emitted = [
    if (entry != null) entry,
    for (final kernel in order)
      if (!baseKeys.contains(kernel.key)) kernel,
  ];

  final outBuilder = BytesBuilder(copy: false);
  if (platform != null) {
    outBuilder.add(cache.dillBytesOf(platform, inputs));
  }
  for (final kernel in emitted) {
    outBuilder.add(cache.dillBytesOf(kernel.path, inputs));
  }
  File(output).writeAsBytesSync(outBuilder.takeBytes());

  if (writeKeysPath != null) {
    final keysOut = StringBuffer();
    for (final k in emitted) {
      keysOut.writeln(k.key);
      for (final def in k.defines) {
        keysOut.writeln(def);
      }
    }
    File(writeKeysPath).writeAsStringSync(keysOut.toString());
  }
  return 0;
}

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
