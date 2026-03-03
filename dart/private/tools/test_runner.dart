import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final env = Platform.environment;
  final dartKey = env['RULES_DART_DART'];
  final manifestKey = env['RULES_DART_PKG_MANIFEST'];
  final mainKey = env['RULES_DART_MAIN'];

  if (dartKey == null || manifestKey == null || mainKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_PKG_MANIFEST=$manifestKey');
    stderr.writeln('  RULES_DART_MAIN=$mainKey');
    exit(1);
  }

  final r = Runfiles.create();
  final dart = r.rlocation(dartKey);
  final manifestPath = r.rlocation(manifestKey);
  final main = r.rlocation(mainKey);

  // Generate package_config.json at runtime with absolute rootUri paths.
  // This is necessary because on Windows (manifest-only runfiles mode),
  // relative rootUri paths in package_config.json would resolve against
  // the config file's real filesystem location (in the output tree), not
  // its runfiles tree position.
  final pkgConfig = _generatePackageConfig(r, manifestPath);

  final result = Process.runSync(
    dart,
    ['--packages=$pkgConfig', main],
    stderrEncoding: systemEncoding,
    stdoutEncoding: systemEncoding,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  // Clean up temp file
  try {
    File(pkgConfig).parent.deleteSync(recursive: true);
  } catch (_) {}

  exit(result.exitCode);
}

/// Reads the packages manifest and generates a package_config.json with
/// absolute rootUri file:// URIs derived from rlocation.
///
/// Manifest format (one package per line):
///   <name>\t<runfiles_root>\t<runfiles_representative_file>
String _generatePackageConfig(Runfiles r, String manifestPath) {
  final lines = File(manifestPath)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .toList();

  final packages = <Map<String, String>>[];
  for (final line in lines) {
    final parts = line.split('\t');
    if (parts.length != 3) continue;

    final name = parts[0];
    final root = parts[1];
    final repFile = parts[2];

    // Resolve the representative file to an absolute path
    final absFile = r.rlocation(repFile);

    // Derive the package root by stripping the suffix
    final suffix = repFile.substring(root.length + 1); // e.g. "lib/foo.dart"
    final absRoot =
        absFile.substring(0, absFile.length - suffix.length - 1) +
        Platform.pathSeparator;

    packages.add({
      'name': name,
      'rootUri': Uri.directory(absRoot).toString(),
      'packageUri': 'lib/',
    });
  }

  final config = json.encode({
    'configVersion': 2,
    'packages': packages,
  });

  final tmpDir = Directory.systemTemp.createTempSync('dart_test_');
  final configFile = File('${tmpDir.path}${Platform.pathSeparator}package_config.json');
  configFile.writeAsStringSync(config);
  return configFile.path;
}
