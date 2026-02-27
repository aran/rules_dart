import 'dart:io';

/// Provides access to Bazel runfiles — data files made available at runtime
/// via the `data` attribute of rules like `dart_binary`.
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
  final String _directory;

  Runfiles._(this._directory);

  /// Creates a [Runfiles] instance by resolving the runfiles directory.
  ///
  /// Resolution order:
  /// 1. `RUNFILES_DIR` environment variable (set by `bazel test`)
  /// 2. `<executable>.runfiles` directory next to the running binary
  ///    (works with `bazel run` — uses `Platform.executable` which
  ///    preserves the symlink path, same as Go's `os.Args[0]`)
  ///
  /// Throws [StateError] if no runfiles directory can be found.
  factory Runfiles.create() {
    final env = Platform.environment['RUNFILES_DIR'];
    if (env != null && env.isNotEmpty) {
      return Runfiles._(env);
    }

    // Use Platform.executable (not resolvedExecutable) to preserve the
    // symlink path. Bazel materializes .runfiles/ next to the symlink,
    // not next to the resolved binary.
    final exe = Platform.executable;
    final candidate = '$exe.runfiles';
    if (Directory(candidate).existsSync()) {
      return Runfiles._(candidate);
    }

    throw StateError(
      'Could not find runfiles directory. '
      'Run via `bazel run` or `bazel test`.',
    );
  }

  /// Returns the absolute path to a runfile.
  ///
  /// [path] is the runfiles-relative path, e.g. `_main/web/echo_client.js`.
  String rlocation(String path) {
    return '$_directory/$path';
  }
}
