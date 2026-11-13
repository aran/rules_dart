import 'dart:async';
import 'dart:io';

Future<void> main() async {
  stdout.writeln('printed before hanging');
  stderr.writeln('written to stderr before hanging');
  // A pending timer, so the VM has a reason to stay up.
  await Completer<void>().future.timeout(const Duration(hours: 1));
}
