import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final env = Platform.environment;
  final dartKey = env['RULES_DART_DART'];
  final pkgConfigKey = env['RULES_DART_PKG_CONFIG'];
  final mainKey = env['RULES_DART_MAIN'];

  if (dartKey == null || pkgConfigKey == null || mainKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_PKG_CONFIG=$pkgConfigKey');
    stderr.writeln('  RULES_DART_MAIN=$mainKey');
    exit(1);
  }

  final r = Runfiles.create();
  final dart = r.rlocation(dartKey);
  final pkgConfig = r.rlocation(pkgConfigKey);
  final main = r.rlocation(mainKey);

  final result = Process.runSync(
    dart,
    ['--packages=$pkgConfig', main],
    stderrEncoding: systemEncoding,
    stdoutEncoding: systemEncoding,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exit(result.exitCode);
}
