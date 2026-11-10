// What a persistent worker's compiler may read through the kernel roots.
//
// Bazel's contract is that an action reads only its declared inputs. A
// sandbox enforces it with a tree of those inputs; an unsandboxed worker runs
// in the exec root, where the compiler, looking a file up under each kernel
// root in turn, would find whatever is on disk: a sibling the target does not
// hold, or a stale output of a target Bazel no longer builds shadowing the
// declared source at its path. Its roots point into a tree of the declared
// sources instead.
import 'dart:io';

/// A directory holding declared input files at the paths the exec root has
/// them, relative paths that climb out of it (a sibling repository) included.
class DeclaredView {
  DeclaredView._(this._dir, this._cwd, this._execRoot);

  /// Stages each of [paths] (a file, or a directory's files) that [declared]
  /// covers: a declared path, or a file under a declared directory (a tree
  /// artifact). Paths are relative to the working directory, the exec root;
  /// [roots] are the kernel roots that [of] will map.
  ///
  /// A file may come more than once (an executable's `main` is also in its
  /// `srcs`, a directory beside a file in it, one path spelled two ways) and
  /// is staged once. Each place in the view holds the file at that same path
  /// in the exec root, so two sources can never claim one place.
  factory DeclaredView.stage({
    required Iterable<String> paths,
    required Iterable<String> declared,
    required Iterable<String> roots,
  }) {
    final cwd = _normal(Directory.current.path);
    String relative(String path) => _relativeTo(cwd, _normal(path));

    final covered = {for (final d in declared) relative(d)};
    bool isDeclared(String path) {
      for (var at = path; ; at = _parent(at)) {
        if (covered.contains(at)) return true;
        if (_parent(at) == at) return false;
      }
    }

    final staged = <String>{};
    for (final path in paths) {
      final List<String> files;
      if (FileSystemEntity.isDirectorySync(path)) {
        files = [
          // Followed: a sandbox stages a tree artifact's files as links.
          for (final f in Directory(
            path,
          ).listSync(recursive: true, followLinks: true))
            if (f is File) relative(f.path),
        ];
      } else {
        files = [relative(path)];
      }
      staged.addAll(files.where(isDeclared));
    }

    // The exec root sits as deep in the view as the paths climb above it, so
    // that `..` leads where it does on disk.
    var climb = 0;
    for (final path in [...staged, ...roots.map(relative)]) {
      if (_isAbsolute(path)) continue;
      final up = path.split('/').takeWhile((s) => s == '..').length;
      if (up > climb) climb = up;
    }
    final dir = Directory.systemTemp.createTempSync('kernel_tool_inputs');
    final top = _normal(dir.path);
    final segments = cwd.split('/').skip(1).toList();
    final execRoot = [
      top,
      ...segments.skip(segments.length - climb.clamp(0, segments.length)),
    ].join('/');
    final view = DeclaredView._(dir, cwd, execRoot);

    final made = <String>{};
    for (final f in staged) {
      final at = view.of(f);
      if (made.add(_parent(at))) {
        Directory(_parent(at)).createSync(recursive: true);
      }
      // A link costs a fifth of a copy. Windows makes links only for an
      // administrator or in developer mode, so there it is a copy.
      if (Platform.isWindows) {
        File(f).copySync(at);
      } else {
        Link(at).createSync(_isAbsolute(f) ? f : _normal('$cwd/$f'));
      }
    }
    return view;
  }

  final Directory _dir;
  final String _cwd;
  final String _execRoot;

  /// Where [path], relative to the exec root or absolute, is in the view.
  String of(String path) {
    final relative = _relativeTo(_cwd, _normal(path));
    if (_isAbsolute(relative)) {
      return '${_normal(_dir.path)}/.outside/${relative.replaceAll(':', '')}';
    }
    return _normal('$_execRoot/$relative');
  }

  void delete() => _dir.deleteSync(recursive: true);
}

/// [directory], an absolute path, as the `file:` URI a compiler's
/// `--multi-root` takes.
///
/// The compiler resolves each root against its working directory as a URI,
/// where a Windows path's drive letter (`C:/...`) would read as a scheme.
String rootArgument(String directory, {bool? windows}) =>
    Uri.directory(directory, windows: windows).toString();

/// [path] with `/` separators and `.` and inner `..` segments folded.
String _normal(String path) {
  final p = path.replaceAll(r'\', '/');
  final out = <String>[];
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..' && out.isNotEmpty && out.last != '..') {
      out.removeLast();
    } else {
      out.add(s);
    }
  }
  final joined = out.join('/');
  if (p.startsWith('/')) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

bool _isAbsolute(String normal) =>
    normal.startsWith('/') || RegExp(r'^[A-Za-z]:(/|$)').hasMatch(normal);

String _relativeTo(String cwd, String normal) {
  if (normal == cwd) return '.';
  if (normal.startsWith('$cwd/')) return normal.substring(cwd.length + 1);
  return normal;
}

String _parent(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? (slash == 0 ? '/' : '.') : path.substring(0, slash);
}
