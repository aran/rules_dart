// Trains an app-JIT snapshot, so that the snapshot does not depend on where or
// how it was built.
//
// Two rules use it: `dart_binary` in `jit-snapshot` mode, which trains on the
// program itself, and `dart_test_runner_snapshot`, which trains the
// `package:test` runner on one real test. It is pure Dart (no shell), so it
// runs on any host the rules support. The exec SDK's `dart` runs it from
// source, so it needs no build of its own.
//
// Usage:
//   dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<version> \
//       --snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] \
//       [--env=KEY=VALUE]... [--copy=DEST=SOURCE]... [--copy-tree=DEST=DIR]... \
//       -- <dart arguments>
//
// The `<dart arguments>` are what `dart` runs in the training: the script
// first, then its own arguments. Paths in them are relative to the scratch
// directory, where each `--copy` and `--copy-tree` places its files.
//
// The snapshot should not depend on how it was built. Four things aim at that:
//  * `--deterministic` makes the VM's own choices repeat, so one training run
//    and the next write the same bytes. `--no-background-compilation` keeps
//    optimizing compiles on the training thread.
//  * The absolute length of the directory the training runs in changes the
//    snapshot. So the training runs in a scratch directory whose name has a
//    fixed length (a random suffix of fixed length), under relative arguments.
//    The scratch directory is private to the run, so concurrent actions that
//    share a `/tmp` cannot collide. On Windows there is no such root, and the
//    rules build no snapshot there.
//  * The environment names nothing but paths relative to the scratch directory.
//  * The training VM runs from a fixed path, `/tmp/rules_dart_vm-<version>/bin`,
//    which holds a copy of the SDK's `dart` (and `dartvm`). The absolute path of
//    the training binary changes the snapshot, so a copy at one path per SDK
//    version is what makes the snapshot the same across SDK installs. Every
//    copy is byte-identical, so concurrent actions may write the same file.
//
// A program whose own training run is not deterministic (it reads the clock,
// random numbers, or files outside the build) yields a snapshot that differs
// between builds, whatever this tool does.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

void main(List<String> argv) {
  if (argv.isNotEmpty && argv.first == '--aot') {
    _runAot(argv.sublist(1));
    return;
  }
  String? dart;
  String? dartvm;
  String? sdkVersion;
  String? snapshot;
  var enableAsserts = false;
  final env = <String, String>{};
  final copies = <_Pair>[];
  final trees = <_Pair>[];

  var i = 0;
  for (; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--') {
      i++;
      break;
    }
    if (arg == '--enable-asserts') {
      enableAsserts = true;
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq < 0) _usage('unknown argument $arg');
    final name = arg.substring(0, eq);
    final value = arg.substring(eq + 1);
    switch (name) {
      case '--dart':
        dart = value;
      case '--dartvm':
        dartvm = value;
      case '--sdk-version':
        sdkVersion = value;
      case '--snapshot':
        snapshot = value;
      case '--env':
        final pair = _Pair.parse(value, arg);
        env[pair.key] = pair.value;
      case '--copy':
        copies.add(_Pair.parse(value, arg));
      case '--copy-tree':
        trees.add(_Pair.parse(value, arg));
      default:
        _usage('unknown argument $arg');
    }
  }
  final dartArgs = argv.sublist(i);
  if (dart == null ||
      sdkVersion == null ||
      snapshot == null ||
      dartArgs.isEmpty) {
    _usage(
      '--dart, --sdk-version, --snapshot and the dart arguments are required',
    );
  }

  final out = File(snapshot).absolute;
  final trainingVm = _stableVm(
    dart: File(dart).absolute.path,
    dartvm: dartvm == null ? null : File(dartvm).absolute.path,
    sdkVersion: sdkVersion,
  );
  final exitCode = _trainInScratch(
    dart: trainingVm,
    dartArgs: dartArgs,
    enableAsserts: enableAsserts,
    env: env,
    copies: [for (final c in copies) _Pair(c.key, File(c.value).absolute.path)],
    trees: [
      for (final t in trees) _Pair(t.key, Directory(t.value).absolute.path),
    ],
    out: out,
  );
  if (exitCode != 0) exit(exitCode);
  if (!out.existsSync()) {
    stderr.writeln(
      'app_jit_snapshot: the training run of ${dartArgs.first} wrote no '
      'snapshot to ${out.path}',
    );
    exit(1);
  }
}

Never _usage(String problem) {
  stderr.writeln(
    'app_jit_snapshot: $problem\n'
    'usage: dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<v> '
    '--snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] [--env=K=V]... '
    '[--copy=D=S]... [--copy-tree=D=DIR]... -- <dart arguments>',
  );
  exit(64);
}

/// Returns the path of the training `dart`: a copy at a fixed path for
/// [sdkVersion], made from [dart] and [dartvm] when they are not there yet.
///
/// Under the Linux sandbox `/tmp` is private to each action, so the copy is
/// removed with the action. Elsewhere one copy per SDK version stays in `/tmp`,
/// and it is not deleted afterwards: another action may be using it. A version
/// is taken to name one binary; a copy with other bytes is replaced.
String _stableVm({
  required String dart,
  required String? dartvm,
  required String sdkVersion,
}) {
  final bin = Directory('/tmp/rules_dart_vm-$sdkVersion/bin');
  bin.createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart');
  if (dartvm != null) _installCopy(dartvm, '${bin.path}/dartvm');
  return '${bin.path}/dart';
}

/// Makes [target] an executable copy of [source], unless it is one already.
///
/// The copy is written under a name unique to this process, marked `0755`, then
/// renamed over [target]. A rename replaces the file in one step, so a reader
/// sees the old file or the new one, never a partial copy, and a process that
/// is running the old file keeps it.
void _installCopy(String source, String target) {
  final src = File(source);
  final dst = File(target);
  if (dst.existsSync() &&
      dst.lengthSync() == src.lengthSync() &&
      _sameBytes(src, dst)) {
    return;
  }
  final tmp = File('$target.$pid.${Random().nextInt(1 << 31)}.tmp');
  tmp.writeAsBytesSync(src.readAsBytesSync());
  chmodFile(tmp.path, 0x1ed);
  tmp.renameSync(target);
}

bool _sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

/// A `KEY=VALUE` (or `DEST=SOURCE`) option value. Splits at the first `=`.
class _Pair {
  const _Pair(this.key, this.value);

  final String key;
  final String value;

  static _Pair parse(String text, String arg) {
    final eq = text.indexOf('=');
    if (eq < 0) _usage('expected KEY=VALUE in $arg');
    return _Pair(text.substring(0, eq), text.substring(eq + 1));
  }
}

/// Runs the training in a fresh scratch directory and copies the snapshot it
/// writes to [out]. Returns the training run's exit code.
///
/// The scratch directory is removed whatever the outcome. `exit` is not called
/// in here: it would skip the cleanup.
int _trainInScratch({
  required String dart,
  required List<String> dartArgs,
  required bool enableAsserts,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
  required File out,
}) {
  // A private directory per run, so concurrent snapshot actions that share a
  // `/tmp` (no sandbox, or a shared one) cannot collide. The random suffix is
  // fixed-length, so the absolute path has the same length on every run.
  final scratch = Directory('/tmp').createTempSync('rules_dart_snapshot.');
  try {
    // Every input is copied to its relative place, so the run needs only
    // relative paths.
    for (final c in copies) {
      _copyFile(c.value, '${scratch.path}/${c.key}');
    }
    for (final t in trees) {
      _copyTree(t.value, '${scratch.path}/${t.key}');
    }

    // The training run keeps the VM flags that make the snapshot repeat, and
    // none that name a host path. The scratch directory is the working
    // directory, so every relative path resolves inside it.
    //
    // The runner keeps its default reporter and timeout, and no file reporter
    // is passed. With the file reporter, and with the explicit reporter and
    // timeout, the same inputs gave different snapshots from one run to the
    // next; with none of them, ten runs gave one snapshot. Nothing here reads a
    // report, and the test's exit code is all the training needs.
    final result = Process.runSync(
      dart,
      [
        '--deterministic',
        // Optimizing compilation stays on the training thread, so the functions
        // the snapshot holds optimized do not depend on when a background
        // compile happens to finish. (The stability measured for this tool was
        // with the flag in place; its own contribution was not measured
        // separately.)
        '--no-background-compilation',
        // Code for the VM's baseline CPU rather than the build machine's. The
        // intent is cross-CPU identity, so a cache can share the snapshot.
        '--target_unknown_cpu',
        if (enableAsserts) '--enable-asserts',
        '--snapshot-kind=app-jit',
        '--snapshot=snapshot.jit',
        ...dartArgs,
      ],
      workingDirectory: scratch.path,
      environment: env,
      includeParentEnvironment: false,
    );

    // Bazel echoes any action output, so a clean run stays silent.
    if (result.exitCode != 0) {
      stdout.write(result.stdout as String);
      stderr.write(result.stderr as String);
      return result.exitCode;
    }
    final written = File('${scratch.path}/snapshot.jit');
    if (written.existsSync()) {
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(written.readAsBytesSync());
    }
    return 0;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Copies every file under [from] to the same relative place under [to].
void _copyTree(String from, String to) {
  final source = Directory(from);
  final entities = source.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    if (entity is File) {
      final relative = entity.path.substring(source.path.length + 1);
      _copyFile(entity.path, '$to/$relative');
    }
  }
}

/// Copies [from] to [to] by content, creating the parent directories of [to].
///
/// Writes bytes rather than `File.copySync` so read-only input modes from a
/// sandbox or remote executor are not carried onto the scratch copy.
void _copyFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

/// Compiles a pre-built kernel `.dill` to an AOT snapshot (`--mode=aot-snapshot`)
/// or self-contained AOT executable (`--mode=exe`) without invoking `dartdev`.
///
/// `dart compile exe` runs through `dartdev`, which walks ancestor directories
/// up to `/` probing `pubspec.yaml` and `.dart_tool/package_config.json` (for
/// native-asset hook discovery) and spawns `/usr/bin/chmod` via `PATH`. Driving
/// `gen_snapshot --deterministic` directly and writing a fresh executable from
/// `dartaotruntime` plus the ELF snapshot (marking it `0755` via libc `chmod`)
/// keeps the compile strictly hermetic inside the action sandbox, even when
/// inputs are staged read-only and no shell or coreutils exist.
void _runAot(List<String> argv) {
  String? dart;
  String? mode;
  String? recordedUses;
  String? outputPath;
  String? dillPath;
  var enableAsserts = false;
  final extraGenSnapshotOptions = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--enable-asserts') {
      enableAsserts = true;
    } else if (arg == '--verbosity=error') {
      // Ignored: gen_snapshot is silent on success.
    } else if (arg.startsWith('--dart=')) {
      dart = arg.substring('--dart='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else if (arg.startsWith('--recorded-uses=')) {
      recordedUses = arg.substring('--recorded-uses='.length);
    } else if (arg.startsWith('--extra-gen-snapshot-options=')) {
      final opts = arg.substring('--extra-gen-snapshot-options='.length);
      for (final opt in opts.split(',')) {
        if (opt.isNotEmpty) extraGenSnapshotOptions.add(opt);
      }
    } else if (arg == '-o') {
      outputPath = argv[++i];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (!arg.startsWith('-')) {
      dillPath = arg;
    } else {
      stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
      exit(64);
    }
  }

  if (dart == null || mode == null || outputPath == null || dillPath == null) {
    stderr.writeln(
      'app_jit_snapshot --aot: --dart, --mode, -o, and input dill are required',
    );
    exit(64);
  }

  final sdkBin = File(dart).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime';
  final genSnapshot = '$sdkBin/utils/gen_snapshot';

  // On non-ELF hosts (e.g. macOS Mach-O executables), `dart compile exe` wraps
  // the snapshot in a signed Mach-O segment; delegate to `dart compile` there.
  if (mode == 'exe' && !_isElfFile(File(dartaotruntime))) {
    final compileArgs = <String>[
      'compile',
      mode,
      '--verbosity=error',
      if (enableAsserts) '--enable-asserts',
      if (recordedUses != null) '--recorded-uses=$recordedUses',
      for (final opt in extraGenSnapshotOptions)
        '--extra-gen-snapshot-options=$opt',
      '-o',
      outputPath,
      dillPath,
    ];
    final res = Process.runSync(dart, compileArgs);
    if (res.exitCode != 0) {
      stdout.write(res.stdout as String);
      stderr.write(res.stderr as String);
      exit(res.exitCode);
    }
    return;
  }

  final tmpDir = Directory.systemTemp.createTempSync('dart_aot_');
  try {
    var activeDill = dillPath;
    if (recordedUses != null) {
      final productPlatform =
          '$sdkBin/../lib/_internal/vm_platform_product.dill';
      final strongPlatform = '$sdkBin/../lib/_internal/vm_platform_strong.dill';
      final platformDill = File(productPlatform).existsSync()
          ? productPlatform
          : strongPlatform;
      final recordedDill = '${tmpDir.path}/recorded.dill';
      final gkRes = Process.runSync(dartaotruntime, [
        '$sdkBin/snapshots/gen_kernel_aot.dart.snapshot',
        '--platform=$platformDill',
        '--aot',
        '--tfa',
        '--no-embed-sources',
        '--from-dill=$dillPath',
        '--recorded-usages-file=$recordedUses',
        '-o',
        recordedDill,
        dillPath,
      ]);
      if (gkRes.exitCode != 0) {
        stdout.write(gkRes.stdout as String);
        stderr.write(gkRes.stderr as String);
        exit(gkRes.exitCode);
      }
      activeDill = recordedDill;
    }

    final elfPath = mode == 'aot-snapshot'
        ? outputPath
        : '${tmpDir.path}/snapshot.elf';
    final gsRes = Process.runSync(genSnapshot, [
      '--deterministic',
      '--snapshot_kind=app-aot-elf',
      '--elf=$elfPath',
      if (enableAsserts) '--enable_asserts',
      ...extraGenSnapshotOptions,
      activeDill,
    ]);
    if (gsRes.exitCode != 0) {
      stdout.write(gsRes.stdout as String);
      stderr.write(gsRes.stderr as String);
      exit(gsRes.exitCode);
    }

    if (mode == 'exe') {
      writeAppAotElfExe(
        dartaotruntime: File(dartaotruntime),
        snapshotElf: File(elfPath),
        output: File(outputPath),
      );
    }
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

bool _isElfFile(File file) {
  if (!file.existsSync()) return false;
  final raf = file.openSync();
  try {
    final magic = raf.readSync(4);
    return magic.length == 4 &&
        magic[0] == 0x7f &&
        magic[1] == 0x45 &&
        magic[2] == 0x4c &&
        magic[3] == 0x46;
  } finally {
    raf.closeSync();
  }
}

/// Writes a self-contained AOT ELF executable to [output] by concatenating
/// [dartaotruntime], zero padding up to a 64 KiB page boundary, [snapshotElf],
/// and the 16-byte app-JIT/AOT trailer, then marks [output] executable (`0755`).
///
/// Does not use `File.copySync`: under remote execution and read-only sandboxes,
/// [dartaotruntime] has mode `0555` (or `0444`), and `copySync` copies that
/// read-only mode onto [output], causing a subsequent open for append to fail
/// with `EACCES`. Writing a fresh file and setting `0755` via `libc`'s `chmod`
/// avoids both copying read-only permissions and spawning `/bin/chmod`.
void writeAppAotElfExe({
  required File dartaotruntime,
  required File snapshotElf,
  required File output,
}) {
  const pageSize = 65536;
  output.parent.createSync(recursive: true);
  if (output.existsSync()) {
    output.deleteSync();
  }
  final runtimeBytes = dartaotruntime.readAsBytesSync();
  final runtimeLen = runtimeBytes.length;
  final padLen = (pageSize - (runtimeLen % pageSize)) % pageSize;
  final offset = runtimeLen + padLen;

  final raf = output.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeFromSync(runtimeBytes);
    if (padLen > 0) {
      raf.writeFromSync(Uint8List(padLen));
    }
    raf.writeFromSync(snapshotElf.readAsBytesSync());
    final trailer = ByteData(16)
      ..setUint64(0, offset, Endian.little)
      ..setUint8(8, 0xdc)
      ..setUint8(9, 0xdc)
      ..setUint8(10, 0xf6)
      ..setUint8(11, 0xf6)
      ..setUint8(12, 0x00)
      ..setUint8(13, 0x00)
      ..setUint8(14, 0x00)
      ..setUint8(15, 0x00);
    raf.writeFromSync(trailer.buffer.asUint8List());
  } finally {
    raf.closeSync();
  }
  chmodFile(output.path, 0x1ed);
}

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _ChmodNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _ChmodDart = int Function(ffi.Pointer<ffi.Uint8>, int);

/// Sets POSIX permission bits [mode] on [path] via libc's `chmod(2)`.
void chmodFile(String path, int mode) {
  if (Platform.isWindows) return;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final chmod = lib.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed for chmod', path);
  }
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    final rc = chmod(ptr, mode);
    if (rc != 0) {
      throw FileSystemException('chmod failed (rc=$rc)', path);
    }
  } finally {
    free(ptr);
  }
}
