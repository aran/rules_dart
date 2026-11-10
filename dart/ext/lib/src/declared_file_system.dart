/// A view of the file system that holds only what a codegen action declared.
///
/// Bazel's contract for an action is that it reads only its declared inputs.
/// A sandbox enforces that by building a tree of those inputs; a persistent
/// worker runs in the real execroot, so nothing does, and the package
/// config's `rootUri`s point at whole package directories. This provider is
/// what the shim's analyzer and asset reader see instead: undeclared files and
/// folders do not exist in it. It also ends every walk up from the staging
/// directory (`analysis_options.yaml`, `pubspec.yaml`, the Blaze and GN
/// workspace probes), so where the system temp directory lives cannot change
/// what a generator sees.
library;

import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart';
import 'package:path/path.dart' as p;

/// A [ResourceProvider] over [base] that shows only files under [roots] and
/// files listed in [files]. Folders that lead to a visible path are visible,
/// listing only their visible children.
///
/// Paths are compared after [p.Context.canonicalize], so `..` segments and,
/// on Windows, letter case do not matter. Symlinks are not followed: a path is
/// visible by the name it is reached through, which is how Bazel names inputs.
class DeclaredResourceProvider implements ResourceProvider {
  DeclaredResourceProvider(
    this.base, {
    required Iterable<String> roots,
    Iterable<String> files = const [],
  }) {
    final ctx = base.pathContext;
    for (final r in roots) {
      _roots.add(ctx.canonicalize(r));
    }
    for (final f in files) {
      _files.add(ctx.canonicalize(f));
    }
    for (final path in [..._roots, ..._files]) {
      var dir = ctx.dirname(path);
      while (_ancestors.add(dir)) {
        final up = ctx.dirname(dir);
        if (up == dir) break;
        dir = up;
      }
    }
  }

  final ResourceProvider base;
  final Set<String> _roots = {};
  final Set<String> _files = {};
  final Set<String> _ancestors = {};

  bool _underRoot(String canonical) {
    final ctx = base.pathContext;
    for (var dir = canonical; ; dir = ctx.dirname(dir)) {
      if (_roots.contains(dir)) return true;
      if (ctx.dirname(dir) == dir) return false;
    }
  }

  /// Whether a file at [path] may be seen.
  bool fileVisible(String path) {
    final c = base.pathContext.canonicalize(path);
    return _files.contains(c) || _underRoot(c);
  }

  /// Whether a folder at [path] may be seen.
  bool folderVisible(String path) {
    final c = base.pathContext.canonicalize(path);
    return _ancestors.contains(c) || _underRoot(c);
  }

  @override
  p.Context get pathContext => base.pathContext;

  @override
  File getFile(String path) => _DeclaredFile(this, base.getFile(path));

  @override
  Folder getFolder(String path) => _DeclaredFolder(this, base.getFolder(path));

  @override
  Link getLink(String path) => base.getLink(path);

  @override
  Resource getResource(String path) => _wrap(base.getResource(path));

  @override
  Folder? getStateLocation(String pluginId) => null;

  Resource _wrap(Resource r) =>
      r is Folder ? _DeclaredFolder(this, r) : _DeclaredFile(this, r as File);
}

abstract class _DeclaredResource implements Resource {
  _DeclaredResource(this.provider, this._base);

  @override
  final DeclaredResourceProvider provider;
  final Resource _base;

  bool get _visible;

  Never _absent() =>
      throw PathNotFoundException(path, 'Not an input of this action');

  @override
  bool get exists => _visible && _base.exists;

  @override
  Folder get parent => _DeclaredFolder(provider, _base.parent);

  @override
  String get path => _base.path;

  @override
  String get shortName => _base.shortName;

  @override
  void delete() => _base.delete();

  @override
  bool isOrContains(String path) => _base.isOrContains(path);

  @override
  Resource resolveSymbolicLinksSync() {
    if (!_visible) _absent();
    // The analyzer resolves links only to detect cycles while walking the
    // folders it analyses, which are the shim's staging directory: copies,
    // never links. Following a link would also leave the names Bazel gave
    // the inputs, which are the names the declared set is keyed by.
    return this;
  }

  @override
  Uri toUri() => _base.toUri();

  @override
  ResourceWatcher watch() => _base.watch();

  @override
  bool operator ==(Object other) =>
      other is _DeclaredResource && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path;
}

class _DeclaredFile extends _DeclaredResource implements File {
  _DeclaredFile(super.provider, File super.base);

  File get _file => _base as File;

  @override
  bool get _visible => provider.fileVisible(path);

  @override
  int get lengthSync => _visible ? _file.lengthSync : _absent();

  @override
  int get modificationStamp => _visible ? _file.modificationStamp : _absent();

  @override
  File copyTo(Folder parentFolder) => throw UnsupportedError('copyTo');

  @override
  Uint8List readAsBytesSync() => _visible ? _file.readAsBytesSync() : _absent();

  @override
  String readAsStringSync() => _visible ? _file.readAsStringSync() : _absent();

  @override
  File renameSync(String newPath) => throw UnsupportedError('renameSync');

  @override
  void writeAsBytesSync(List<int> bytes) =>
      throw UnsupportedError('writeAsBytesSync');

  @override
  void writeAsStringSync(String content) =>
      throw UnsupportedError('writeAsStringSync');
}

class _DeclaredFolder extends _DeclaredResource implements Folder {
  _DeclaredFolder(super.provider, Folder super.base);

  Folder get _folder => _base as Folder;

  @override
  bool get _visible => provider.folderVisible(path);

  @override
  bool get isRoot => _folder.isRoot;

  @override
  String canonicalizePath(String path) => _folder.canonicalizePath(path);

  @override
  bool contains(String path) => _folder.contains(path);

  @override
  Folder copyTo(Folder parentFolder) => throw UnsupportedError('copyTo');

  @override
  void create() => throw UnsupportedError('create');

  @override
  Resource getChild(String relPath) =>
      provider._wrap(_folder.getChild(relPath));

  @override
  File getChildAssumingFile(String relPath) => getFile(relPath);

  @override
  Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  List<Resource> getChildren() {
    if (!_visible) _absent();
    return [
      for (final child in _folder.getChildren())
        if (child is Folder
            ? provider.folderVisible(child.path)
            : provider.fileVisible(child.path))
          provider._wrap(child),
    ];
  }

  @override
  File getFile(String relPath) =>
      _DeclaredFile(provider, _folder.getFile(relPath));

  @override
  Folder getFolder(String relPath) =>
      _DeclaredFolder(provider, _folder.getFolder(relPath));
}
