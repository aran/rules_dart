import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final r = Runfiles.create();
  final path = r.rlocation('_main/dart/runfiles/example/data/message.txt');

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('FAIL: data file not found at $path');
    exit(1);
  }

  final content = file.readAsStringSync().trim();
  if (content == 'Hello from runfiles!') {
    print('PASS: read expected message via rlocation');
  } else {
    stderr.writeln('FAIL: expected "Hello from runfiles!", got "$content"');
    exit(1);
  }
}
