/// Reading, writing and joining kernel lists: the programs a modular
/// `dart_test` (and, through rules_dart's link, another rule set's test) runs.
///
/// A kernel list is a text file the Dart VM runs as the program its kernels
/// make together: `#@dill`, then one kernel path a line, each ending in a
/// newline. A relative path is resolved against the directory the list was
/// reached through, not the one a symbolic link to it points into. The first
/// kernel is the program's root: its `main` is the one that runs.
///
/// rules_dart writes each line as the path from the list to that kernel in a
/// runfiles tree. Where runfiles are a manifest and not a tree (Windows, or
/// `bazel run` resolving through one), those paths lead nowhere, so a launcher
/// finds the kernels with [kernelsInRunfiles] and then either writes a list
/// naming them where they are ([writeKernelList]) or, for a program that takes
/// one file, joins them ([joinKernels]).
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// The first line of a kernel list.
const kernelListHeader = '#@dill';

/// The flag setting that turns kernel lists off, for the message of a failure.
const kernelListOff = '--@rules_dart//dart:kernel_list=false';

/// A kernel list could not be read, found or joined. Its message says what
/// failed and names [kernelListOff], which builds joined kernels instead.
final class KernelListException implements Exception {
  KernelListException(this.message, [this.cause]);

  /// What failed.
  final String message;

  /// The error underneath, if there was one.
  final Object? cause;

  @override
  String toString() =>
      '$message${cause == null ? '' : ': $cause'}; set $kernelListOff to use '
      'joined kernels';
}

/// Whether the file at [path] is a kernel list rather than a kernel.
bool isKernelList(String path) {
  const magic = '$kernelListHeader\n';
  final file = File(path).openSync();
  try {
    return String.fromCharCodes(file.readSync(magic.length)) == magic;
  } finally {
    file.closeSync();
  }
}

/// The kernels the program at [path] is made of: those a kernel list names, in
/// order; or [path] itself when it is a kernel.
///
/// Each line is resolved as the VM resolves it: one the platform takes as
/// absolute stands, and any other is appended to [path] up to its last
/// [Platform.pathSeparator] (on Windows a `/` does not end the directory).
List<String> kernelsAt(String path) {
  if (!isKernelList(path)) return [path];
  final directory = path.substring(
    0,
    path.lastIndexOf(Platform.pathSeparator) + 1,
  );
  return [
    for (final line in _lines(path))
      _vmAbsolute(line) ? line : '$directory$line',
  ];
}

/// The kernels the program at runfiles path [rlocationPath] is made of, each
/// found through [runfiles]: those a kernel list names, in order, each line
/// taken as the path from the list to the kernel in runfiles; or the program
/// itself when it is a kernel.
///
/// Works whether [runfiles] is a directory tree or a manifest. Throws a
/// [KernelListException] when the program, or a kernel it names, cannot be
/// found.
List<String> kernelsInRunfiles(Runfiles runfiles, String rlocationPath) {
  final path = _rlocation(runfiles, rlocationPath);
  if (path == null) {
    throw KernelListException('$rlocationPath is not in runfiles');
  }
  final bool list;
  try {
    list = isKernelList(path);
  } on FileSystemException catch (e) {
    throw KernelListException('cannot read $rlocationPath in runfiles', e);
  }
  if (!list) return [path];
  final directory = rlocationPath.split('/')..removeLast();
  return [
    for (final line in _lines(path))
      _isAbsolute(line)
          ? line
          : _found(runfiles, directory, line, rlocationPath),
  ];
}

/// Writes a kernel list at [path] naming [kernels], in order; the first is the
/// program's root. Each is written as given, so give absolute paths unless the
/// list will be reached from where relative ones resolve.
void writeKernelList(String path, List<String> kernels) {
  if (kernels.isEmpty) {
    throw ArgumentError.value(kernels, 'kernels', 'names no kernel');
  }
  for (final kernel in kernels) {
    if (kernel.contains('\n')) {
      throw ArgumentError.value(kernel, 'kernels', 'has a newline');
    }
  }
  File(path).writeAsStringSync('$kernelListHeader\n${kernels.join('\n')}\n');
}

/// One program joined from several kernels, at [path] while it is open.
final class JoinedKernel {
  JoinedKernel._(this.path, this._close);

  /// Where a process can read the program while this is open: a file, or on
  /// Linux `/proc/<this process>/fd/<n>`, which another process opens as a
  /// file but which the Dart VM can only take as a `file:` URI ([uri]).
  final String path;

  /// [path] as a `file:` URI.
  String get uri => Uri.file(path).toString();

  final void Function() _close;
  var _closed = false;

  /// Releases the program: the memory it holds, or the file and the
  /// directory made for it. A process already reading it keeps reading.
  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

/// [kernels], in order, joined into one program for a process that takes a
/// single kernel file, such as `flutter_tester`. Close it once that process
/// has read it, or exited.
///
/// On Linux the program is written to memory (`memfd_create`, filled with
/// `sendfile`), not to disk, and [JoinedKernel.path] names it through this
/// process, which must outlive the read. Elsewhere it is a file in a new
/// directory under [temporaryDirectory] (by default the system's), removed on
/// close. A single kernel is not copied: its own path is returned.
///
/// Throws a [KernelListException] when the join fails, on Linux the memory
/// file included: there is no quiet second way.
JoinedKernel joinKernels(List<String> kernels, {String? temporaryDirectory}) {
  if (kernels.isEmpty) {
    throw ArgumentError.value(kernels, 'kernels', 'names no kernel');
  }
  if (kernels.length == 1) return JoinedKernel._(kernels.single, () {});
  if (Platform.isLinux) return _LinuxMemory.join(kernels);
  final Directory directory;
  try {
    directory = Directory(temporaryDirectory ?? Directory.systemTemp.path)
        .createTempSync('kernel_list.');
  } on FileSystemException catch (e) {
    throw KernelListException('cannot make a directory to join kernels in', e);
  }
  final path = '${directory.path}${Platform.pathSeparator}program.dill';
  try {
    final out = File(path).openSync(mode: FileMode.writeOnly);
    final buffer = Uint8List(1 << 20);
    try {
      for (final kernel in kernels) {
        final input = File(kernel).openSync();
        try {
          for (var n = input.readIntoSync(buffer); n > 0;) {
            out.writeFromSync(buffer, 0, n);
            n = input.readIntoSync(buffer);
          }
        } finally {
          input.closeSync();
        }
      }
    } finally {
      out.closeSync();
    }
  } on FileSystemException catch (e) {
    directory.deleteSync(recursive: true);
    throw KernelListException('cannot join kernels into $path', e);
  }
  return JoinedKernel._(path, () {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      throw KernelListException('cannot remove the joined kernel', e);
    }
  });
}

Iterable<String> _lines(String path) => const LineSplitter()
    .convert(File(path).readAsStringSync())
    .skip(1)
    .where((line) => line.isNotEmpty);

final _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// Whether the VM takes kernel-list line [path] as absolute.
bool _vmAbsolute(String path) => Platform.isWindows
    ? path.startsWith(r'\\') || _windowsAbsolute.hasMatch(path)
    : path.startsWith('/');

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    _windowsAbsolute.hasMatch(path);

/// Where [runfiles] has [rlocationPath], or null if it has none.
String? _rlocation(Runfiles runfiles, String rlocationPath) {
  try {
    return runfiles.rlocation(rlocationPath);
  } on StateError {
    return null;
  }
}

/// Where [line] of the kernel list at runfiles path [list], in [directory],
/// finds its kernel.
String _found(
  Runfiles runfiles,
  List<String> directory,
  String line,
  String list,
) {
  final out = <String>[];
  for (final segment in [...directory, ...line.split('/')]) {
    if (segment == '.' || segment.isEmpty) continue;
    if (segment != '..') {
      out.add(segment);
    } else if (out.isEmpty) {
      throw KernelListException(
        'the kernel list $list names $line, which leaves the runfiles tree',
      );
    } else {
      out.removeLast();
    }
  }
  final rlocationPath = out.join('/');
  final path = _rlocation(runfiles, rlocationPath);
  if (path == null || !File(path).existsSync()) {
    throw KernelListException(
      'the kernel list $list names $line, which is not in runfiles (as '
      '$rlocationPath)',
    );
  }
  return path;
}

/// Linux's anonymous memory files, through `libc`.
abstract final class _LinuxMemory {
  static const _cloexec = 1; // MFD_CLOEXEC

  /// [kernels] joined in an anonymous memory file.
  static JoinedKernel join(List<String> kernels) {
    final _Libc libc;
    try {
      libc = _Libc();
    } on ArgumentError catch (e) {
      throw KernelListException('this libc has no memfd_create', e);
    }
    final name = libc.string('kernel_list');
    final fd = libc.memfdCreate(name, _cloexec);
    final errno = libc.errno;
    libc.free(name);
    if (fd < 0) {
      throw KernelListException('memfd_create failed', OSError('', errno));
    }
    try {
      for (final kernel in kernels) {
        libc.sendAll(fd, kernel);
      }
    } on FileSystemException catch (e) {
      libc.close(fd);
      throw KernelListException('cannot join kernels in memory', e);
    }
    return JoinedKernel._('/proc/$pid/fd/$fd', () => libc.close(fd));
  }
}

final class _Libc {
  _Libc()
    : memfdCreate = _lib
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32),
            int Function(Pointer<Uint8>, int)
          >('memfd_create');

  static final _lib = DynamicLibrary.process();

  final int Function(Pointer<Uint8>, int) memfdCreate;

  // `open` takes a mode only with O_CREAT; without it the two-argument form
  // is the call on every Linux ABI.
  static final _open = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32),
        int Function(Pointer<Uint8>, int)
      >('open');
  static final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _sendfile = _lib
      .lookupFunction<
        IntPtr Function(Int32, Int32, Pointer<Int64>, IntPtr),
        int Function(int, int, Pointer<Int64>, int)
      >('sendfile');
  static final _malloc = _lib
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  static final _free = _lib
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );

  static const _eintr = 4;
  static const _oRdonlyCloexec = 0x80000; // O_RDONLY | O_CLOEXEC

  Pointer<Uint8> string(String s) {
    final bytes = utf8.encode(s);
    final p = _malloc(bytes.length + 1);
    p.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return p;
  }

  void free(Pointer<Uint8> p) => _free(p);

  void close(int fd) => _close(fd);

  int get errno => _errno().value;

  /// Appends the whole of the file at [path] to [fd].
  void sendAll(int fd, String path) {
    final name = string(path);
    final input = _open(name, _oRdonlyCloexec);
    free(name);
    if (input < 0) {
      throw FileSystemException(
        'cannot open',
        path,
        OSError('', _errno().value),
      );
    }
    try {
      var left = File(path).lengthSync();
      while (left > 0) {
        // At most 0x7ffff000 bytes go in one call.
        final sent = _sendfile(fd, input, nullptr, left);
        if (sent < 0) {
          final errno = _errno().value;
          if (errno == _eintr) continue;
          throw FileSystemException('cannot copy', path, OSError('', errno));
        }
        if (sent == 0) {
          throw FileSystemException('ended early while copying', path);
        }
        left -= sent;
      }
    } finally {
      _close(input);
    }
  }
}
