// Where each source lives as a URI, and which package and platform it belongs
// to. Sources are read through one multi-root filesystem scheme so that no
// absolute path reaches the output.
import 'dart:convert';

const rootScheme = 'org-dartlang-root';

/// Turns an exec path into a path relative to the longest of [roots] that
/// contains it. `.` (the exec root) contains everything, so it is the fallback.
String rootRelative(String execPath, List<String> roots) {
  final path = _clean(execPath);
  var best = '';
  for (final root in roots.map(_cleanRoot)) {
    if (root.length > best.length && path.startsWith('$root/')) best = root;
  }
  return best.isEmpty ? path : path.substring(best.length + 1);
}

String _clean(String path) {
  var p = path.replaceAll(r'\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  return p;
}

String _cleanRoot(String root) {
  var r = _clean(root);
  while (r.endsWith('/')) {
    r = r.substring(0, r.length - 1);
  }
  return r == '.' ? '' : r;
}

/// The `org-dartlang-root:` form of a root-relative path.
String rootUri(String relative) => '$rootScheme:///$relative';

const _rootPrefix = '$rootScheme:///';

/// The package a `package:` URI names, or null.
String? packageNameOf(String uri) {
  if (!uri.startsWith('package:')) return null;
  final slash = uri.indexOf('/');
  return uri.substring('package:'.length, slash < 0 ? uri.length : slash);
}

class PackageConfig {
  PackageConfig._(this.names, this._libs);

  /// [configRelative] is the config's own root-relative path; a relative
  /// `rootUri` resolves against its directory.
  factory PackageConfig.parse(String json, String configRelative) {
    final base = Uri.parse(rootUri(configRelative));
    final names = <String>{};
    final libs = <_PackageLib>[];
    final packages = (jsonDecode(json) as Map)['packages'] as List;
    for (final entry in packages.cast<Map<String, dynamic>>()) {
      final name = entry['name'] as String;
      names.add(name);
      final root = base.resolve(entry['rootUri'] as String);
      if (root.scheme != rootScheme) continue;
      final rootDir = root.path.endsWith('/')
          ? root
          : root.replace(path: '${root.path}/');
      final lib = rootDir.resolve((entry['packageUri'] as String?) ?? '');
      var prefix = Uri.decodeFull(lib.path);
      if (prefix.startsWith('/')) prefix = prefix.substring(1);
      if (prefix.isNotEmpty && !prefix.endsWith('/')) prefix = '$prefix/';
      var rootPath = Uri.decodeFull(rootDir.path);
      if (rootPath.startsWith('/')) rootPath = rootPath.substring(1);
      libs.add(_PackageLib(name, prefix, rootPath));
    }
    libs.sort((a, b) => b.prefix.length.compareTo(a.prefix.length));
    return PackageConfig._(names, libs);
  }

  final Set<String> names;
  final List<_PackageLib> _libs;

  /// The package a library URI belongs to: the one a `package:` URI names, or
  /// the one whose directory holds an `org-dartlang-root:` file.
  String? packageOf(String uri) {
    if (uri.startsWith('package:')) return packageNameOf(uri);
    return _containing(uri)?.name;
  }

  _PackageLib? _containing(String uri) {
    if (!uri.startsWith(_rootPrefix)) return null;
    final relative = uri.substring(_rootPrefix.length);
    _PackageLib? best;
    for (final lib in _libs) {
      if (relative.startsWith(lib.root) &&
          (best == null || lib.root.length > best.root.length)) {
        best = lib;
      }
    }
    return best;
  }

  /// The URI importers use for a root-relative path: `package:` under a
  /// package's lib directory, `org-dartlang-root:` anywhere else.
  String uriFor(String relative) {
    for (final lib in _libs) {
      if (relative.startsWith(lib.prefix)) {
        return 'package:${lib.name}/${relative.substring(lib.prefix.length)}';
      }
    }
    return rootUri(relative);
  }

  /// The root-relative directory `package:<name>/` names, ending in `/`, or
  /// null when the package is not addressed through the kernel roots.
  String? libDirOf(String name) {
    for (final lib in _libs) {
      if (lib.name == name) return lib.prefix;
    }
    return null;
  }

  /// [uri] spelled the way [uriFor] spells it. A relative import from outside
  /// lib/ into it names the file by its root URI, while its module knows it by
  /// its package URI.
  String canonical(String uri) => uri.startsWith(_rootPrefix)
      ? uriFor(uri.substring(_rootPrefix.length))
      : uri;
}

class _PackageLib {
  const _PackageLib(this.name, this.prefix, this.root);
  final String name;

  /// The root-relative directory importers reach as `package:<name>/`.
  final String prefix;

  /// The root-relative directory of the whole package.
  final String root;
}

/// The `dart:` libraries a `libraries.json` target provides: its own
/// `libraries` plus those of every target it `include`s.
Set<String> supportedLibraries(String librariesJson, String target) {
  final spec = jsonDecode(librariesJson) as Map;
  final out = <String>{};
  final seen = <String>{};
  void add(String name) {
    if (!seen.add(name)) return;
    final entry = spec[name];
    if (entry is! Map) return;
    out.addAll(((entry['libraries'] as Map?) ?? const {}).keys.cast<String>());
    for (final include in (entry['include'] as List?) ?? const []) {
      add((include as Map)['target'] as String);
    }
  }

  add(target);
  return out;
}

/// [ref] resolved against the library URI [base].
String resolveUri(String base, String ref) {
  final Uri parsed;
  try {
    parsed = Uri.parse(ref);
  } on FormatException {
    return ref;
  }
  if (parsed.hasScheme) return ref;
  return Uri.parse(base).resolveUri(parsed).toString();
}
