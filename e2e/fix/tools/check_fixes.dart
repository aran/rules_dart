// Asserts the exact contents of a `dart_fix` fixes tree and extracts one file
// from it, so a `diff_test` can compare that file against a golden.
//
// The exhaustive listing is the load-bearing part: it is what says a generated
// file was never written back. An assertion that only checked the files it
// expected to find would pass just as happily with an extra `.freezed.dart`
// sitting beside them.
import 'dart:io';

void main(List<String> args) {
  String? fixes;
  String? out;
  String? path;
  final expected = <String>{};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--fixes':
        fixes = args[++i];
      case '--out':
        out = args[++i];
      case '--path':
        path = args[++i];
      case '--content':
        expected.add(args[++i]);
      default:
        stderr.writeln('check_fixes: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (fixes == null || out == null) {
    stderr.writeln('check_fixes: --fixes and --out are required');
    exit(64);
  }

  final actual = <String>{};
  for (final entity in Directory(fixes).listSync(recursive: true)) {
    if (entity is File) {
      actual.add(entity.path.substring(fixes.length + 1).replaceAll(r'\', '/'));
    }
  }

  final unexpected = actual.difference(expected).toList()..sort();
  final missing = expected.difference(actual).toList()..sort();
  if (unexpected.isNotEmpty || missing.isNotEmpty) {
    stderr.writeln('check_fixes: $fixes does not hold the expected files.');
    for (final p in unexpected) {
      stderr.writeln('  unexpected (dart_fix wrote a file it must not): $p');
    }
    for (final p in missing) {
      stderr.writeln('  missing (dart_fix did not fix it): $p');
    }
    exit(1);
  }

  if (path == null) {
    File(out).writeAsStringSync('');
    return;
  }
  File(out).writeAsBytesSync(File('$fixes/$path').readAsBytesSync());
}
