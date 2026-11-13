// Asserts exactly which files a target's changes files rewrite, and extracts
// one file's new content, so a `diff_test` can compare it against a golden.
//
// The exhaustive listing is the load-bearing part: it is what says a generated
// file was never proposed for writing. An assertion that only checked the
// files it expected would pass just as happily with an extra `.freezed.dart`
// beside them. Nothing may be dropped either: a dropped change means the fixer
// reached a file the aspect meant to keep out of its way.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final changes = <String>[];
  final expected = <String>{};
  String? out;
  String? path;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--changes':
        changes.add(args[++i]);
      case '--out':
        out = args[++i];
      case '--path':
        path = args[++i];
      case '--content':
        expected.add(args[++i]);
      default:
        stderr.writeln('check_changes: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (changes.isEmpty || out == null) {
    stderr.writeln('check_changes: --changes and --out are required');
    exit(64);
  }

  final content = <String, String>{};
  final dropped = <Object?>[];
  for (final file in changes) {
    final json = jsonDecode(File(file).readAsStringSync()) as Map;
    for (final c in json['changes'] as List) {
      content[c['path'] as String] = c['content'] as String;
    }
    dropped.addAll(json['dropped'] as List);
  }

  var failed = false;
  for (final p in content.keys.toSet().difference(expected)) {
    stderr.writeln('  unexpected (a file it must not rewrite): $p');
    failed = true;
  }
  for (final p in expected.difference(content.keys.toSet())) {
    stderr.writeln('  missing (a file it must rewrite): $p');
    failed = true;
  }
  for (final d in dropped) {
    stderr.writeln('  dropped: $d');
    failed = true;
  }
  if (failed) {
    stderr.writeln('check_changes: the changes are not the expected ones');
    exit(1);
  }
  File(out).writeAsStringSync(path == null ? 'ok\n' : content[path]!);
}
