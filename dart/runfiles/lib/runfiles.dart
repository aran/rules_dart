import 'dart:convert';
import 'dart:io';

/// Provides access to Bazel runfiles — data files made available at runtime
/// via the `data` attribute of rules like `dart_binary`.
///
/// Supports three resolution strategies:
/// 1. **Directory-based** — a runfiles directory tree (Unix default)
/// 2. **Manifest-based** — a flat file mapping runfile paths to real paths
///    (Windows without symlink support, or `--noenable_runfiles`)
/// 3. **Both** — tries directory first, falls back to manifest
///
/// Usage:
/// ```dart
/// import 'package:runfiles/runfiles.dart';
///
/// void main() {
///   final r = Runfiles.create();
///   final path = r.rlocation('my_dep/path/to/data.txt');
///   print(File(path).readAsStringSync());
/// }
/// ```
class Runfiles {
  final String? _directory;
  final Map<String, String>? _manifest;
  final String? _manifestPath;

  /// Bzlmod repo-mapping table. Keyed by `(sourceCanonical, apparent)` →
  /// targetCanonical. Empty-string source canonical means "main module".
  /// See https://bazel.build/external/extension#bzlmod_repo_mapping for
  /// the format.
  final Map<(String, String), String> _repoMapping;

  final String _defaultSourceRepo;

  /// Low-level constructor that takes pre-parsed state. Most callers
  /// should use [Runfiles.create] (or [forRepo] on an existing instance);
  /// `fromState` exists for tests and for embedders that supply their
  /// own runfiles tree representation.
  Runfiles.fromState({
    this._directory,
    this._manifest,
    this._manifestPath,
    Map<(String, String), String>? repoMapping,
    this._defaultSourceRepo = '',
  }) : _repoMapping = repoMapping ?? const {};

  /// Creates a [Runfiles] instance by probing environment variables and
  /// filesystem paths.
  ///
  /// Resolution order:
  /// 1. `RUNFILES_DIR` environment variable (set by `bazel test`)
  /// 2. `RUNFILES_MANIFEST_FILE` environment variable (manifest-only mode)
  /// 3. `<executable>.runfiles` directory next to the running binary
  /// 4. `<executable>.exe.runfiles` directory (Windows .exe launcher)
  /// 5. `<executable>.runfiles_manifest` file
  /// 6. `<executable>.exe.runfiles_manifest` file
  ///
  /// A `MANIFEST` inside a runfiles directory found either way is read when
  /// no other manifest was: under `--noenable_runfiles` (Windows' default) it
  /// is all the directory holds. A manifest wins over the directory.
  ///
  /// A directory found next to the executable is held by its resolved
  /// path, so [rlocation] keeps working after a symlink on the way to it,
  /// such as `bazel-bin`, is repointed.
  ///
  /// If a `_repo_mapping` file is present at the runfiles root (always
  /// the case under bzlmod; absent under WORKSPACE-only builds), it's
  /// parsed and consulted by [rlocation] for apparent → canonical repo
  /// translation.
  ///
  /// [sourceRepository] is the canonical bzlmod repo name of the caller —
  /// the default `''` means "main module" and is correct for any binary
  /// whose `dart_binary` target lives in the main Bazel module. A binary
  /// shipping as a Bazel dep of another module should pass its own
  /// canonical name (e.g. `'foo+'`) so apparent-repo lookups in
  /// [rlocation] resolve from that module's perspective.
  ///
  /// Throws [StateError] if no runfiles can be found.
  factory Runfiles.create({String sourceRepository = ''}) {
    final env = Platform.environment;
    String? directory;
    Map<String, String>? manifest;
    String? manifestPath;

    // 1. RUNFILES_DIR environment variable
    final runfilesDir = env['RUNFILES_DIR'];
    if (runfilesDir != null &&
        runfilesDir.isNotEmpty &&
        Directory(runfilesDir).existsSync()) {
      directory = Directory(runfilesDir).absolute.path;
    }

    // 2. RUNFILES_MANIFEST_FILE environment variable
    final manifestFile = env['RUNFILES_MANIFEST_FILE'];
    if (manifestFile != null &&
        manifestFile.isNotEmpty &&
        File(manifestFile).existsSync()) {
      manifest = _parseManifest(manifestFile);
      manifestPath = File(manifestFile).absolute.path;
    }

    // 3-6. Probe from executable path
    final tried = [
      for (final (name, value) in [
        ('RUNFILES_DIR', runfilesDir),
        ('RUNFILES_MANIFEST_FILE', manifestFile),
      ])
        value == null || value.isEmpty ? '$name (unset)' : '$name=$value',
    ];
    if (directory == null && manifest == null) {
      // Use Platform.executable (not resolvedExecutable) to preserve the
      // symlink path. Bazel materializes .runfiles/ next to the symlink,
      // not next to the resolved binary.
      final exe = Platform.executable;

      for (final candidate in ['$exe.runfiles', '$exe.exe.runfiles']) {
        tried.add(candidate);
        if (Directory(candidate).existsSync()) {
          // Hold the tree where it really is, not the path that found it.
          // That path runs through the symlink, and `./bazel-bin/...` is
          // repointed by the next build in another configuration.
          directory = Directory(candidate).resolveSymbolicLinksSync();
          break;
        }
      }

      for (final candidate in [
        '$exe.runfiles_manifest',
        '$exe.exe.runfiles_manifest',
      ]) {
        tried.add(candidate);
        if (File(candidate).existsSync()) {
          manifest = _parseManifest(candidate);
          manifestPath = File(candidate).absolute.path;
          break;
        }
      }
    }

    // A manifest inside the runfiles directory is all that remains of the
    // tree under `--noenable_runfiles`; the official libraries read it too.
    if (manifest == null && directory != null) {
      final inside = File('$directory/MANIFEST');
      if (inside.existsSync()) {
        manifest = _parseManifest(inside.path);
        manifestPath = inside.absolute.path;
      }
    }

    if (directory == null && manifest == null) {
      throw StateError(
        'Could not find runfiles directory or manifest; looked at '
        '${tried.join(', ')}. Run via `bazel run` or `bazel test`.',
      );
    }

    return Runfiles.fromState(
      directory: directory,
      manifest: manifest,
      manifestPath: manifestPath,
      repoMapping: _loadRepoMapping(directory: directory, manifest: manifest),
      defaultSourceRepo: sourceRepository,
    );
  }

  /// Returns a [Runfiles] that shares the underlying directory, manifest,
  /// and repo-mapping table but resolves [rlocation] from
  /// [sourceRepository]'s perspective.
  ///
  /// Library code that calls [rlocation] without an explicit `sourceRepo:`
  /// should hold a `forRepo`-derived view, otherwise lookups use the
  /// binary's source repo and resolve apparent names from the wrong
  /// module's perspective under bzlmod with version skew.
  Runfiles forRepo(String sourceRepository) => Runfiles.fromState(
    directory: _directory,
    manifest: _manifest,
    manifestPath: _manifestPath,
    repoMapping: _repoMapping,
    defaultSourceRepo: sourceRepository,
  );

  /// The environment variables that let a program this one starts find the
  /// same runfiles: `RUNFILES_DIR` and `RUNFILES_MANIFEST_FILE`, whichever
  /// were found.
  ///
  /// A child process cannot find them on its own when its executable is not
  /// the one the runfiles belong to (a Dart VM running a kernel, say), so pass
  /// these in its environment, as Bazel's other runfiles libraries do.
  Map<String, String> get environment => {
    if (_directory != null) 'RUNFILES_DIR': _directory,
    if (_manifestPath != null) 'RUNFILES_MANIFEST_FILE': _manifestPath,
  };

  /// Returns the absolute path to a runfile.
  ///
  /// An absolute [path] is returned unchanged. A path with an empty, `.` or
  /// `..` segment throws [ArgumentError], as the official libraries refuse
  /// it. In manifest mode a path inside a listed directory (a tree
  /// artifact) resolves against the nearest listed prefix.
  ///
  /// [path] is the runfiles-relative path. The first segment is treated
  /// as an *apparent* repo name and looked up in `_repo_mapping` to find
  /// the *canonical* repo Bazel actually wrote into runfiles (e.g.
  /// apparent `quiche_dart` → canonical `quiche_dart+` under bzlmod).
  ///
  /// Pass [sourceRepo] (canonical name of the calling repo) to look up
  /// the mapping from a non-main module's perspective. Defaults to the
  /// main module ('').
  ///
  /// If the apparent name has no mapping, the path is used verbatim —
  /// preserves backwards compatibility for already-canonical paths and
  /// for non-bzlmod (WORKSPACE) builds where _repo_mapping is absent.
  String rlocation(String path, {String? sourceRepo}) {
    if (_isAbsolute(path)) return path;
    _checkNormalized(path);
    final source = sourceRepo ?? _defaultSourceRepo;
    final translated = _applyRepoMapping(path, source);

    // Manifest takes priority — it's the source of truth on Windows and
    // in manifest-only mode.
    final manifest = _manifest;
    if (manifest != null) {
      // Exact entry first, then the nearest listed ancestor directory
      // (a tree artifact is one entry for everything under it).
      var prefix = translated;
      var suffix = '';
      while (true) {
        final mapped = manifest[prefix];
        if (mapped != null) return '$mapped$suffix';
        final slash = prefix.lastIndexOf('/');
        if (slash < 0) break;
        suffix = prefix.substring(slash) + suffix;
        prefix = prefix.substring(0, slash);
      }
    }

    if (_directory != null) return '$_directory/$translated';

    throw StateError('Could not resolve runfile: $path');
  }

  static final _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

  static bool _isAbsolute(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      _windowsAbsolute.hasMatch(path);

  static void _checkNormalized(String path) {
    if (path.isEmpty ||
        path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ArgumentError.value(
        path,
        'path',
        'must be a normalized runfiles path with no empty, "." or ".." '
            'segments',
      );
    }
  }

  String _applyRepoMapping(String path, String sourceRepo) {
    if (_repoMapping.isEmpty) return path;
    final slash = path.indexOf('/');
    final apparent = slash < 0 ? path : path.substring(0, slash);
    final rest = slash < 0 ? '' : path.substring(slash);
    final canonical = _repoMapping[(sourceRepo, apparent)];
    if (canonical == null) return path;
    return '$canonical$rest';
  }

  /// Parses a Bazel runfiles manifest file.
  ///
  /// A plain line is `<runfiles-path> <real-path>`, split at the first
  /// space. A line starting with a space is escaped: both fields use `\s`
  /// for a space, `\n` for a newline and `\b` for a backslash.
  static Map<String, String> _parseManifest(String path) {
    final result = <String, String>{};
    for (final line in File(path).readAsLinesSync()) {
      final escaped = line.startsWith(' ');
      final body = escaped ? line.substring(1) : line;
      final idx = body.indexOf(' ');
      if (idx <= 0) continue;
      var key = body.substring(0, idx);
      var value = body.substring(idx + 1);
      if (escaped) {
        key = _unescape(key);
        value = _unescape(value);
      }
      result[key] = value;
    }
    return result;
  }

  static String _unescape(String s) => s.replaceAllMapped(
    RegExp(r'\\([snb])'),
    (m) => const {'s': ' ', 'n': '\n', 'b': '\\'}[m[1]]!,
  );

  /// Parses bzlmod `_repo_mapping` file *content* into a
  /// `(sourceCanonical, apparent) → targetCanonical` table. Each line is
  /// `source,apparent,target`; the source field may be empty (main
  /// module). Lines with a different column count are skipped.
  static Map<(String, String), String> parseRepoMapping(String content) {
    final out = <(String, String), String>{};
    for (final line in const LineSplitter().convert(content)) {
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length != 3) continue;
      out[(parts[0], parts[1])] = parts[2];
    }
    return out;
  }

  static Map<(String, String), String> _loadRepoMapping({
    String? directory,
    Map<String, String>? manifest,
  }) {
    String? content;
    final mapped = manifest?['_repo_mapping'];
    if (mapped != null && File(mapped).existsSync()) {
      content = File(mapped).readAsStringSync();
    } else if (directory != null) {
      final f = File('$directory/_repo_mapping');
      if (f.existsSync()) content = f.readAsStringSync();
    }
    return content == null ? const {} : parseRepoMapping(content);
  }
}
