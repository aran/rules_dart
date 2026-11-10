// A web entrypoint in the same 3.6 package.
// ignore_for_file: no_wildcard_variable_uses
String describe(String alpha, String beta, String gamma) => '$alpha $gamma';

void main() {
  final _ = 'web';
  // A web entrypoint has no `dart:io`; printing is its only output.
  // ignore: avoid_print
  print(describe(
      'the first argument', 'the second argument', 'the third one, $_'));
}
