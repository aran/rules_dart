import 'dart:io';

/// The name the command line reports for itself.
const String cliName = 'cli';

/// The command line's own entry point. A test that imports this library must run its
/// own `main`, not this one: this one reports that it ran and exits non-zero.
void main(List<String> args) {
  stdout.writeln('the library main ran, not the test');
  exit(64);
}
