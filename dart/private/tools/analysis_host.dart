// Hosts the SDK's analysis server for the analyze and fix runners: run by the
// SDK's VM (`dartvm`) from source, it runs the server's JIT snapshot as an isolate of
// this one process, so ending the process ends the server, with nothing left
// to orphan.
//
//   dartvm analysis_host.dart <cache> <server snapshot> <server arguments>...
//
// The server reads requests from this process's stdin and writes to its
// stdout. It does not exit when stdin closes, so this process ends itself:
// when the process that started it is gone, on SIGTERM (not on Windows, which
// has no such signal), or when the server isolate ends. It then removes
// <cache>, the server's cache directory, which nobody else would remove after
// a kill.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dartvm analysis_host.dart <cache> <server snapshot> <arguments>...',
    );
    exit(64);
  }
  final cache = args[0];
  final exited = ReceivePort();
  final serverDone = exited.first;
  Isolate? server;
  var ending = false;
  // Stops the server before removing its cache: a server still writing into
  // the directory can make the removal fail partway, leaving it behind.
  Future<void> end(int code) async {
    if (ending) return;
    ending = true;
    server?.kill(priority: Isolate.immediate);
    if (server != null) {
      await serverDone.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    final directory = Directory(cache);
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      if (directory.existsSync()) {
        stderr.writeln('The analysis host could not remove $cache: $e');
      }
    }
    exit(code);
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => unawaited(end(0)));
  }
  final bool Function() parentGone;
  try {
    parentGone = Platform.isWindows ? _watchWindowsParent() : _watchParent();
  } on StateError catch (e) {
    stderr.writeln('The analysis host cannot watch its parent: ${e.message}');
    exit(70);
  }
  if (parentGone()) await end(0);
  Timer.periodic(_parentPoll, (_) {
    if (parentGone()) unawaited(end(0));
  });

  final errors = ReceivePort();
  var failed = false;
  errors.listen((error) {
    failed = true;
    stderr.writeln('The analysis server failed: $error');
  });
  server = await Isolate.spawnUri(
    Uri.file(args[1]),
    ['--cache=$cache', ...args.skip(2)],
    null,
    onExit: exited.sendPort,
    onError: errors.sendPort,
  );
  await serverDone;
  await end(failed ? 70 : 0);
}

/// How often the host checks that its parent is alive: how long a server can
/// outlive a runner that was killed.
const _parentPoll = Duration(seconds: 1);

/// Reports whether the process that started this one is gone, on macOS and
/// Linux: a process whose parent dies is handed to another (init, or a
/// subreaper), so its parent id changes.
bool Function() _watchParent() {
  final getppid = DynamicLibrary.process()
      .lookupFunction<Int32 Function(), int Function()>('getppid');
  final parent = getppid();
  return () => getppid() != parent;
}

// What follows is the Windows half. Windows hands nothing to a new parent, so
// a process must hold its parent to know when it ends.

/// `PROCESSENTRY32W`, of which `Process32FirstW` and `Process32NextW` fill
/// in the process id and the parent's.
final class _ProcessEntry extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int usage;
  @Uint32()
  external int processId;
  @Uint64()
  external int defaultHeapId;
  @Uint32()
  external int moduleId;
  @Uint32()
  external int threads;
  @Uint32()
  external int parentProcessId;
  @Int32()
  external int priorityClassBase;
  @Uint32()
  external int flags;
  @Array(260)
  external Array<Uint16> exeFile;
}

/// A `FILETIME`: 100 ns ticks since 1601 in two halves.
final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;

  int get ticks => (high << 32) | low;
}

/// Reports whether the process that started this one has ended, on Windows.
///
/// The host opens a handle to its parent now and asks it, with a wait that
/// never blocks, whether the parent has ended. Holding the handle from
/// start-up is what makes this right where a process id is not: Windows
/// reuses ids, so a parent found again by id some time later may be a
/// stranger, while an open handle names the one process until it is closed.
/// The remaining window is the start itself: a parent that ended before the
/// handle was opened may have had its id reused by then, which shows as a
/// process younger than this one, so that is taken as the parent being gone.
///
/// Throws a [StateError] for what it cannot do rather than leaving the host
/// unwatched.
bool Function() _watchWindowsParent() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final currentProcess = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final currentProcessId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  final createSnapshot = kernel32
      .lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>(
        'CreateToolhelp32Snapshot',
      );
  final firstEntry = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_ProcessEntry>),
        int Function(int, Pointer<_ProcessEntry>)
      >('Process32FirstW');
  final nextEntry = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_ProcessEntry>),
        int Function(int, Pointer<_ProcessEntry>)
      >('Process32NextW');
  final openProcess = kernel32
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
  final processTimes = kernel32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        ),
        int Function(
          int,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        )
      >('GetProcessTimes');
  final waitFor = kernel32
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject',
      );
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final localAlloc = kernel32
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  final localFree = kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  const invalidHandle = -1;
  const snapshotProcesses = 0x2; // TH32CS_SNAPPROCESS
  const zeroInit = 0x40; // LMEM_ZEROINIT
  const synchronize = 0x00100000; // SYNCHRONIZE
  const queryLimited = 0x1000; // PROCESS_QUERY_LIMITED_INFORMATION
  const waitTimeout = 0x102; // WAIT_TIMEOUT

  Pointer<T> alloc<T extends NativeType>(int bytes) =>
      localAlloc(zeroInit, bytes).cast<T>();

  final me = currentProcessId();
  final parentId = () {
    final snapshot = createSnapshot(snapshotProcesses, 0);
    if (snapshot == invalidHandle) {
      throw StateError('CreateToolhelp32Snapshot failed');
    }
    final entry = alloc<_ProcessEntry>(sizeOf<_ProcessEntry>());
    try {
      entry.ref.size = sizeOf<_ProcessEntry>();
      for (
        var more = firstEntry(snapshot, entry);
        more != 0;
        more = nextEntry(snapshot, entry)
      ) {
        if (entry.ref.processId == me) return entry.ref.parentProcessId;
      }
      throw StateError('this process is not in the process snapshot');
    } finally {
      localFree(entry.cast());
      closeHandle(snapshot);
    }
  }();

  final parent = openProcess(synchronize | queryLimited, 0, parentId);
  // No such process: the parent ended before the host got to it.
  if (parent == 0) return () => true;

  final times = alloc<_FileTime>(sizeOf<_FileTime>() * 4);
  try {
    final created = times, ended = times + 1, kernel = times + 2;
    final user = times + 3;
    int createdAt(int process) {
      if (processTimes(process, created, ended, kernel, user) == 0) {
        throw StateError('GetProcessTimes failed');
      }
      return created.ref.ticks;
    }

    // A parent younger than this process is a stranger given the id of one
    // that ended.
    if (createdAt(parent) > createdAt(currentProcess())) return () => true;
  } finally {
    localFree(times.cast());
  }
  return () => waitFor(parent, 0) != waitTimeout;
}
