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
    String? directory,
    Map<String, String>? manifest,
    Map<(String, String), String>? repoMapping,
    String defaultSourceRepo = '',
  })  : _directory = directory,
        _manifest = manifest,
        _repoMapping = repoMapping ?? const {},
        _defaultSourceRepo = defaultSourceRepo;

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

    // 1. RUNFILES_DIR environment variable
    final runfilesDir = env['RUNFILES_DIR'];
    if (runfilesDir != null &&
        runfilesDir.isNotEmpty &&
        Directory(runfilesDir).existsSync()) {
      directory = runfilesDir;
    }

    // 2. RUNFILES_MANIFEST_FILE environment variable
    final manifestFile = env['RUNFILES_MANIFEST_FILE'];
    if (manifestFile != null &&
        manifestFile.isNotEmpty &&
        File(manifestFile).existsSync()) {
      manifest = _parseManifest(manifestFile);
    }

    // 3-6. Probe from executable path
    if (directory == null && manifest == null) {
      // Use Platform.executable (not resolvedExecutable) to preserve the
      // symlink path. Bazel materializes .runfiles/ next to the symlink,
      // not next to the resolved binary.
      final exe = Platform.executable;

      for (final candidate in ['$exe.runfiles', '$exe.exe.runfiles']) {
        if (Directory(candidate).existsSync()) {
          directory = candidate;
          break;
        }
      }

      for (final candidate in [
        '$exe.runfiles_manifest',
        '$exe.exe.runfiles_manifest',
      ]) {
        if (File(candidate).existsSync()) {
          manifest = _parseManifest(candidate);
          break;
        }
      }
    }

    if (directory == null && manifest == null) {
      throw StateError(
        'Could not find runfiles directory or manifest. '
        'Run via `bazel run` or `bazel test`.',
      );
    }

    return Runfiles.fromState(
      directory: directory,
      manifest: manifest,
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
        repoMapping: _repoMapping,
        defaultSourceRepo: sourceRepository,
      );

  /// Returns the absolute path to a runfile.
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
    final source = sourceRepo ?? _defaultSourceRepo;
    final translated = _applyRepoMapping(path, source);

    // Manifest takes priority — it's the source of truth on Windows and
    // in manifest-only mode.
    final mapped = _manifest?[translated];
    if (mapped != null) return mapped;

    if (_directory != null) return '$_directory/$translated';

    throw StateError('Could not resolve runfile: $path');
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
  /// Each line is `<runfiles-path> <real-path>`, separated by a single space.
  static Map<String, String> _parseManifest(String path) {
    final result = <String, String>{};
    for (final line in File(path).readAsLinesSync()) {
      final idx = line.indexOf(' ');
      if (idx > 0) {
        result[line.substring(0, idx)] = line.substring(idx + 1);
      }
    }
    return result;
  }

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
