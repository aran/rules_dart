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
  // its runfiles tree position. It also co-locates a codegen package's
  // source and generated files (which only meet in the runfiles tree).
  final pkgConfig = _generatePackageConfig(r, manifestPath);

  // When the test declares native code assets, compile the main to a kernel
  // that embeds the asset mapping and run the dill (so `@Native` resolves
  // against the Bazel-built libraries).
  final codeAssetsKey = env['RULES_DART_CODE_ASSETS'];
  if (codeAssetsKey != null) {
    exit(_runWithCodeAssets(r, env, dart, pkgConfig, main, codeAssetsKey));
  }

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

/// Compiles [main] to a kernel that embeds the native code-asset mapping, then
/// runs it. The kernel compile happens here (test time, not a build action)
/// because a codegen package's source and generated files only co-locate in
/// the runfiles tree — the same reason `package_config.json` is built at
/// runtime. Each asset uses an `absolute` path resolved via `rlocation`, so no
/// relative-path resolution is involved.
///
/// Code-asset manifest (one per line): `<asset_id>\t<so_runfiles_path>`.
int _runWithCodeAssets(
  Runfiles r,
  Map<String, String> env,
  String dart,
  String pkgConfig,
  String main,
  String codeAssetsKey,
) {
  final genKernel = r.rlocation(env['RULES_DART_GENKERNEL']!);
  final aotRuntime = r.rlocation(env['RULES_DART_AOTRUNTIME']!);
  final platformDill = r.rlocation(env['RULES_DART_PLATFORM']!);
  final abi = env['RULES_DART_ABI']!;

  final assets = <String, dynamic>{};
  for (final line in File(
    r.rlocation(codeAssetsKey),
  ).readAsLinesSync().where((l) => l.isNotEmpty)) {
    final tab = line.indexOf('\t');
    final assetId = line.substring(0, tab);
    final soPath = r.rlocation(line.substring(tab + 1));
    assets[assetId] = ['absolute', soPath];
  }
  // JSON is valid YAML; json.encode handles path escaping (e.g. Windows '\').
  final nativeAssetsYaml = json.encode({
    'format-version': [1, 0, 0],
    'native-assets': {abi: assets},
  });

  final tmp = Directory.systemTemp.createTempSync('dart_test_ca_');
  try {
    final sep = Platform.pathSeparator;
    final yamlFile = File('${tmp.path}${sep}native_assets.yaml')
      ..writeAsStringSync(nativeAssetsYaml);
    final dill = '${tmp.path}${sep}app.dill';

    final gen = Process.runSync(
      aotRuntime,
      [
        genKernel,
        '--platform',
        platformDill,
        '--packages',
        pkgConfig,
        '--native-assets',
        yamlFile.path,
        '-o',
        dill,
        main,
      ],
      stderrEncoding: systemEncoding,
      stdoutEncoding: systemEncoding,
    );
    if (gen.exitCode != 0) {
      stdout.write(gen.stdout);
      stderr.write(gen.stderr);
      stderr.writeln('gen_kernel (native assets) failed.');
      return gen.exitCode;
    }

    final result = Process.runSync(
      dart,
      [dill],
      stderrEncoding: systemEncoding,
      stdoutEncoding: systemEncoding,
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    return result.exitCode;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
      File(pkgConfig).parent.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Reads the packages manifest and generates a package_config.json with
/// absolute rootUri file:// URIs derived from rlocation.
///
/// Manifest format (one package per line):
///   <name>\t<runfiles_root>\t<runfiles_representative_file>\t<language_version>
/// The trailing language_version column is empty when the package didn't
/// declare one; that case is mirrored in the JSON by omitting the
/// `languageVersion` field, matching `generate_package_config`'s behaviour
/// in `dart/private/common.bzl`.
String _generatePackageConfig(Runfiles r, String manifestPath) {
  final lines = File(
    manifestPath,
  ).readAsLinesSync().where((l) => l.isNotEmpty).toList();

  final packages = <Map<String, String>>[];
  for (final line in lines) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;

    final name = parts[0];
    final root = parts[1];
    final repFile = parts[2];
    final languageVersion = parts.length >= 4 ? parts[3] : '';

    // Resolve the representative file to an absolute path
    final absFile = r.rlocation(repFile);

    // Derive the package root by stripping the suffix
    final suffix = repFile.substring(root.length + 1); // e.g. "lib/foo.dart"
    final absRoot =
        absFile.substring(0, absFile.length - suffix.length - 1) +
        Platform.pathSeparator;

    final entry = <String, String>{
      'name': name,
      'rootUri': Uri.directory(absRoot).toString(),
      'packageUri': 'lib/',
    };
    if (languageVersion.isNotEmpty) {
      entry['languageVersion'] = languageVersion;
    }
    packages.add(entry);
  }

  final config = json.encode({'configVersion': 2, 'packages': packages});

  final tmpDir = Directory.systemTemp.createTempSync('dart_test_');
  final configFile = File(
    '${tmpDir.path}${Platform.pathSeparator}package_config.json',
  );
  configFile.writeAsStringSync(config);
  return configFile.path;
}
