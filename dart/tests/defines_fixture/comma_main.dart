import 'dart:io';

/// Prints two declarations whose values contain commas, one from `defines` and
/// one from a front-end flag, so a run observes whether either was cut short on
/// the way through the compile pipeline.
void main() {
  const greeting = String.fromEnvironment('GREETING');
  const more = String.fromEnvironment('MORE');
  stdout.writeln('$greeting;$more');
}
