import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

/// The flag that turns the cache off, which every error names.
const runnerSnapshotFlag = '--@rules_dart//dart:runner_snapshot=false';

/// The variable that puts the cache in a directory of the user's choosing.
const runnerSnapshotDirVariable = 'RULES_DART_RUNNER_SNAPSHOT_DIR';

/// Something went wrong with the runner snapshot cache. The run fails with it:
/// the cache was meant to be used, so running without it would hide that it
/// is not working.
class RunnerSnapshotException implements Exception {
  RunnerSnapshotException(this.message);

  final String message;

  @override
  String toString() =>
      'dart_test: $message\n'
      'The runner snapshot cache only makes the test runner start faster. '
      'Set $runnerSnapshotFlag to run without it, or put it in a directory '
      'tests can write with --test_env=$runnerSnapshotDirVariable=<dir> '
      '--sandbox_writable_path=<dir>.';
}

/// How many runners' snapshots a cache keeps, about 50 MB each: one per SDK
/// and `package:test` lock in use on the machine. Each repository with its own
/// lock has its own, so a few checkouts in a day already make four.
const keptSnapshots = 8;

/// How long a training claim or a half-written snapshot is left to the run
/// that made it. Training takes seconds; one older than this was abandoned by
/// a run that was killed.
const abandonedAfter = Duration(minutes: 10);

final _ours = RegExp(
  r'^[0-9A-Za-z._+-]+-[0-9a-f]{16}(\.snapshot|\.snapshot\.[0-9a-z-]+\.tmp|\.training)$',
);

/// A per-machine cache of the `package:test` runner as an app-JIT snapshot.
///
/// The snapshot is never a Bazel input or output: training is not
/// byte-reproducible (event-loop timing and paths reach it), so Bazel would see
/// new bytes on every run. It can change only how fast the runner starts, never
/// what a test does: the runner's code is the same, compiled ahead.
///
/// A snapshot is named by [key]: the VM that runs it and the runner's digest,
/// both from the build, so a changed runner or SDK never starts from an old
/// one. When there is none, the run starts from the runner's kernel as it
/// would without the cache, and then trains one: the runner again on the
/// same test with a filter no case matches, the VM writing the snapshot as it
/// exits. Training is a run of its own because a test that ends the VM with
/// `exit()` from its isolate stops the VM writing one, and turns its exit code
/// into 255; in the test's own run, that would change its result. Concurrent
/// first runs need no lock: every snapshot is valid, each is written under a
/// name of its own and renamed into place, and the last rename wins. A claim
/// file only spares the other runs the work.
class RunnerSnapshotCache {
  RunnerSnapshotCache._(this.directory, this.key);

  /// The cache for the snapshot named [key], in [directory]: the one named by
  /// `RULES_DART_RUNNER_SNAPSHOT_DIR` in [environment], or this machine's.
  ///
  /// Throws a [RunnerSnapshotException] if the directory cannot be made.
  factory RunnerSnapshotCache.open({
    required String key,
    required Map<String, String> environment,
  }) {
    final chosen = environment[runnerSnapshotDirVariable];
    final Directory directory;
    if (chosen != null && chosen.isNotEmpty) {
      directory = Directory(chosen);
      _create(directory);
    } else {
      directory = _machineDirectory();
    }
    return RunnerSnapshotCache._(directory, key);
  }

  /// The cache's key: [vm] (version, OS and architecture) and the first 16
  /// hex digits of [digest], the runner's SHA-256.
  static String keyOf({required String vm, required String digest}) {
    final hex = digest.trim();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      throw RunnerSnapshotException(
        'the runner digest "$hex" is not a SHA-256',
      );
    }
    return '${vm.replaceAll(RegExp(r'[^0-9A-Za-z._+-]'), '_')}-'
        '${hex.substring(0, 16)}';
  }

  final Directory directory;
  final String key;

  File get snapshot => File(_in('$key.snapshot'));

  File get _claim => File(_in('$key.training'));

  String _in(String name) => '${directory.path}${Platform.pathSeparator}$name';

  /// What this run does: start from the snapshot, or start from the kernel
  /// and train one afterwards.
  ///
  /// A snapshot that is there is marked as used, so that the cache keeps the
  /// ones in use. Otherwise a file is made for the training to write, which
  /// also proves the directory can be written before the test runs.
  RunnerSnapshotPlan plan() {
    final snapshot = this.snapshot;
    if (snapshot.existsSync()) {
      try {
        snapshot.setLastModifiedSync(DateTime.now());
      } on FileSystemException catch (e) {
        throw RunnerSnapshotException(
          'cannot mark the runner snapshot ${snapshot.path} as used: '
          '${_reason(e)}',
        );
      }
      return StartFromSnapshot(snapshot);
    }
    final suffix = '$pid-${Random().nextInt(1 << 32).toRadixString(36)}';
    final into = File(_in('$key.snapshot.$suffix.tmp'));
    try {
      into.createSync(exclusive: true);
    } on FileSystemException catch (e) {
      throw RunnerSnapshotException(
        'cannot write the runner snapshot cache ${directory.path}: '
        '${_reason(e)}',
      );
    }
    return TrainSnapshot(this, into);
  }

  /// Removes a snapshot the VM could not start the runner from, so that the
  /// next run trains another, and returns the error to fail this run with.
  RunnerSnapshotException refused(File snapshot, int exitCode) {
    var removal = 'It is removed, so the next run trains a new one.';
    try {
      snapshot.deleteSync();
    } on FileSystemException catch (e) {
      removal =
          'It could not be removed (${_reason(e)}); remove it to train '
          'a new one.';
    }
    return RunnerSnapshotException(
      'the Dart VM did not start the test runner from its snapshot '
      '${snapshot.path} (exit code $exitCode; any message from the VM is '
      'above). $removal',
    );
  }

  /// Claims the training of this key, or returns `false` when another run
  /// holds a claim it has not abandoned.
  bool _claimTraining() {
    final claim = _claim;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        claim.createSync(exclusive: true);
        return true;
      } on FileSystemException {
        if (!_isAbandoned(claim)) return false;
        try {
          claim.deleteSync();
        } on FileSystemException {
          return false;
        }
      }
    }
    return false;
  }

  void _releaseTraining() {
    try {
      _claim.deleteSync();
    } on FileSystemException {
      // Another run took it over as abandoned and has released it.
    }
  }

  /// Bounds the cache: the [keptSnapshots] snapshots used most recently stay,
  /// with this one among them; older ones go, as do abandoned claims and
  /// half-written snapshots. Only files named as this cache names them.
  void _prune() {
    final snapshots = <File, DateTime>{};
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File || !_ours.hasMatch(name)) continue;
      if (name.endsWith('.snapshot')) {
        if (entity.path != snapshot.path) {
          snapshots[entity] = _modified(entity) ?? DateTime(0);
        }
      } else if (_isAbandoned(entity)) {
        _deleteQuietly(entity);
      }
    }
    final byUse = snapshots.keys.toList()
      ..sort((a, b) => snapshots[b]!.compareTo(snapshots[a]!));
    byUse.skip(keptSnapshots - 1).forEach(_deleteQuietly);
  }

  static bool _isAbandoned(File file) {
    final modified = _modified(file);
    return modified != null &&
        DateTime.now().difference(modified) > abandonedAfter;
  }

  static DateTime? _modified(File file) {
    try {
      return file.lastModifiedSync();
    } on FileSystemException {
      return null;
    }
  }

  /// For a file another run may hold open (Windows refuses to remove one) or
  /// have removed already: the next training tries again.
  static void _deleteQuietly(File file) {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Left for the next training.
    }
  }
}

/// What a run under the cache does.
sealed class RunnerSnapshotPlan {}

/// Start the runner from [snapshot].
final class StartFromSnapshot extends RunnerSnapshotPlan {
  StartFromSnapshot(this.snapshot);

  final File snapshot;
}

/// Start the runner from its kernel, then train a snapshot into [into].
final class TrainSnapshot extends RunnerSnapshotPlan {
  TrainSnapshot(this._cache, this.into);

  final RunnerSnapshotCache _cache;
  final File into;

  /// Trains the snapshot by running [dart] with [vmOptions], then
  /// [runnerArguments] (the runner's kernel and its arguments), and puts it
  /// in place, unless one is there by now or another run is training it.
  ///
  /// Throws a [RunnerSnapshotException] if the VM writes none.
  Future<void> train({
    required String dart,
    List<String> vmOptions = const [],
    required List<String> runnerArguments,
    required String? workingDirectory,
    required Map<String, String> environment,
  }) async {
    final cache = _cache;
    try {
      if (cache.snapshot.existsSync() || !cache._claimTraining()) return;
      try {
        final ProcessResult result;
        try {
          result = await Process.run(
            dart,
            [
              ...vmOptions,
              '--enable-asserts',
              '--snapshot-kind=app-jit',
              '--snapshot=${into.path}',
              ...runnerArguments,
            ],
            workingDirectory: workingDirectory,
            environment: environment,
            includeParentEnvironment: false,
          );
        } on ProcessException catch (e) {
          throw RunnerSnapshotException(
            'training the runner snapshot could not start the VM: $e',
          );
        }
        // The VM exits with 255 when it cannot write the snapshot, and may
        // leave part of one.
        if (result.exitCode == 255 || _size(into) == 0) {
          throw RunnerSnapshotException(
            'training the runner snapshot wrote none (the VM exited with '
            '${result.exitCode}). The training run said:\n'
            '${result.stdout}${result.stderr}',
          );
        }
        try {
          into.renameSync(cache.snapshot.path);
        } on FileSystemException catch (e) {
          // Windows will not replace a file a running test holds open; then
          // another run's snapshot is in place, which serves as well.
          if (!cache.snapshot.existsSync()) {
            throw RunnerSnapshotException(
              'cannot put the trained runner snapshot at '
              '${cache.snapshot.path}: ${_reason(e)}',
            );
          }
        }
        cache._prune();
      } finally {
        cache._releaseTraining();
      }
    } finally {
      RunnerSnapshotCache._deleteQuietly(into);
    }
  }

  /// Removes the file made for the training, when the run ends before it.
  void abandon() => RunnerSnapshotCache._deleteQuietly(into);

  static int _size(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
}

String _reason(FileSystemException e) => e.osError?.message ?? e.message;

void _create(Directory directory) {
  try {
    directory.createSync(recursive: true);
  } on FileSystemException catch (e) {
    throw RunnerSnapshotException(
      'cannot make the runner snapshot cache ${directory.path}: ${_reason(e)}',
    );
  }
}

/// This machine's cache, where a sandboxed test can write and every test,
/// build and checkout of the user shares it:
///
/// - macOS: `/tmp/rules_dart-<uid>/runner`, which Bazel's macOS sandbox
///   lets every action write, outside the home, which a test does not write.
///   `/tmp` is shared by every user, so the directory is per user and must be
///   private to them.
/// - Linux: `/dev/shm/rules_dart-<uid>/runner`, in memory and cleared at
///   reboot. Under Bazel's Linux sandbox `/tmp` is private to each action and
///   the home and output base are read-only; `/dev/shm` is the one place left
///   writable. It is shared by every user, so the directory is per user and
///   must be private to them.
/// - Windows: `rules_dart\runner` in the account's local application data
///   (`%LOCALAPPDATA%`), asked of the shell: Bazel's Windows test environment
///   does not set the variable. Windows has no sandbox.
Directory _machineDirectory() {
  final Directory directory;
  if (Platform.isMacOS || Platform.isLinux) {
    final shared = Platform.isMacOS ? '/tmp' : '/dev/shm';
    final mine = Directory('$shared/rules_dart-${_uid()}');
    createPrivateDirectory(mine);
    directory = Directory('${mine.path}/runner');
  } else if (Platform.isWindows) {
    directory = Directory('${_localAppData()}\\rules_dart\\runner');
  } else {
    throw RunnerSnapshotException(
      'there is no runner snapshot cache on ${Platform.operatingSystem}',
    );
  }
  _create(directory);
  return directory;
}

/// Makes [directory] in a directory every user can write (POSIX), private to
/// this one: `mkdir` with mode 0700, so it is never there with other modes
/// (`Directory.create` takes no mode). One already there must be private,
/// which with this user able to write it means it is theirs; anyone else's
/// could hold a snapshot this user would then run.
void createPrivateDirectory(Directory directory) {
  final mkdir = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('mkdir');
  final path = directory.path.toNativeUtf8();
  try {
    // Fails when it is there already, which is checked below as any other.
    mkdir(path, 0x1c0); // 0700
  } finally {
    malloc.free(path);
  }
  if (FileSystemEntity.isLinkSync(directory.path)) {
    throw RunnerSnapshotException(
      'the runner snapshot cache ${directory.path} is a link; remove it',
    );
  }
  if (!directory.existsSync()) {
    throw RunnerSnapshotException(
      'cannot make the runner snapshot cache ${directory.path}',
    );
  }
  final mode = directory.statSync().mode;
  if (mode & 0x3f != 0) {
    throw RunnerSnapshotException(
      'the runner snapshot cache ${directory.path} can be reached by other '
      'users (mode ${(mode & 0x1ff).toRadixString(8)}); remove it, and the '
      'next run makes it private',
    );
  }
}

int _uid() => DynamicLibrary.process()
    .lookupFunction<Uint32 Function(), int Function()>('getuid')();

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

/// `FOLDERID_LocalAppData`, from the Windows shell.
String _localAppData() {
  final getKnownFolderPath = DynamicLibrary.open('shell32.dll')
      .lookupFunction<
        Int32 Function(
          Pointer<_Guid>,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Utf16>>,
        ),
        int Function(
          Pointer<_Guid>,
          int,
          Pointer<Void>,
          Pointer<Pointer<Utf16>>,
        )
      >('SHGetKnownFolderPath');
  final free = DynamicLibrary.open('ole32.dll')
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CoTaskMemFree');
  final id = calloc<_Guid>();
  final path = calloc<Pointer<Utf16>>();
  try {
    // {F1B32785-6FBA-4FCF-9D55-7B8E7F157091}
    id.ref
      ..data1 = 0xF1B32785
      ..data2 = 0x6FBA
      ..data3 = 0x4FCF;
    const tail = [0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91];
    for (var i = 0; i < tail.length; i++) {
      id.ref.data4[i] = tail[i];
    }
    final result = getKnownFolderPath(id, 0, nullptr, path);
    try {
      if (result != 0) {
        throw RunnerSnapshotException(
          'Windows did not say where local application data goes (HRESULT '
          '0x${(result & 0xffffffff).toRadixString(16)}), which holds the '
          'runner snapshot cache',
        );
      }
      return path.value.toDartString();
    } finally {
      // Freed whether or not the call succeeded, as the API asks.
      free(path.value.cast());
    }
  } finally {
    calloc
      ..free(id)
      ..free(path);
  }
}
