// A package with no library: this binary states its language version, 3.6.
// Reading `_` compiles only below 3.7, where it is still an ordinary variable,
// and the wrapped call below is in the short style only 3.6 produces.
String describe(String alpha, String beta, String gamma) => '$alpha $gamma';

void main() {
  final _ = 'short';
  print(describe(
      'the first argument', 'the second argument', 'the third one, $_'));
}
