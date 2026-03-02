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
///   final path = r.rlocation('_main/web/echo_client.js');
///   print(File(path).readAsStringSync());
/// }
/// ```
class Runfiles {
  final String? _directory;
  final Map<String, String>? _manifest;

  Runfiles._({String? directory, Map<String, String>? manifest})
      : _directory = directory,
        _manifest = manifest;

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
  /// Throws [StateError] if no runfiles can be found.
  factory Runfiles.create() {
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

    return Runfiles._(directory: directory, manifest: manifest);
  }

  /// Returns the absolute path to a runfile.
  ///
  /// [path] is the runfiles-relative path, e.g. `_main/web/echo_client.js`.
  ///
  /// Checks the manifest first (exact match), then falls back to the
  /// directory tree.
  String rlocation(String path) {
    // Manifest takes priority — it's the source of truth on Windows and
    // in manifest-only mode.
    final mapped = _manifest?[path];
    if (mapped != null) return mapped;

    if (_directory != null) return '$_directory/$path';

    throw StateError('Could not resolve runfile: $path');
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
}
