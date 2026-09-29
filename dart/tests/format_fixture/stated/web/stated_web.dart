// A web entrypoint in the same 3.6 package.
String describe(String alpha, String beta, String gamma) => '$alpha $gamma';

void main() {
  final _ = 'web';
  print(describe(
      'the first argument', 'the second argument', 'the third one, $_'));
}
