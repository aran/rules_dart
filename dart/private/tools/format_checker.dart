import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final env = Platform.environment;
  final dartKey = env['RULES_DART_DART'];
  final manifestKey = env['RULES_DART_FORMAT_MANIFEST'];

  if (dartKey == null || manifestKey == null) {
    stderr.writeln('Missing required environment variables.');
    stderr.writeln('  RULES_DART_DART=$dartKey');
    stderr.writeln('  RULES_DART_FORMAT_MANIFEST=$manifestKey');
    exit(1);
  }

  final r = Runfiles.create();
  final dart = r.rlocation(dartKey);
  final manifestPath = r.rlocation(manifestKey);

  final lines = File(manifestPath)
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .toList();

  final sources = lines.map((l) => r.rlocation(l)).toList();

  final result = Process.runSync(
    dart,
    ['format', '--output=none', '--set-exit-if-changed', ...sources],
    stderrEncoding: systemEncoding,
    stdoutEncoding: systemEncoding,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exit(result.exitCode);
}
