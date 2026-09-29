// Compiles only at a language version below 3.7, which this test states.
String describe(String alpha, String beta, String gamma) => '$alpha $gamma';

void main() {
  final _ = 6;
  final described = describe(
      'the first argument', 'the second argument', 'the answer, ${_ * 7}');
  if (!described.endsWith('42')) {
    throw StateError('expected the answer, got: $described');
  }
}
