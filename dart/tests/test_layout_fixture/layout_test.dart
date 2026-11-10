import 'dart:io';

/// Reads by its path, from its package's root (this directory, which holds
/// its library) in runfiles, each kind of runfile a test can
/// read that way: its own `data`, a library's resource, and `data` from
/// another repository. `test_runner_test` runs it without a runfiles tree too.
void main() {
  void expectFile(String path, String Function(String) check) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('missing from ${Directory.current.path}: $path');
      exit(1);
    }
    final problem = check(file.readAsStringSync());
    if (problem.isNotEmpty) {
      stderr.writeln('$path: $problem');
      exit(1);
    }
  }

  String says(String expected, String text) =>
      text.trim() == expected ? '' : 'holds "${text.trim()}", not "$expected"';

  expectFile('data.txt', (t) => says('present', t));
  expectFile('lib/resource.txt', (t) => says('resource', t));
  // Another repository's runfiles are beside this one's, as in a tree: up
  // from `_main/dart/tests/test_layout_fixture`.
  expectFile(
    '../../../../${Platform.environment['EXTERNAL_RLOCATIONPATH']}',
    (t) => t.isEmpty ? 'is empty' : '',
  );
}
