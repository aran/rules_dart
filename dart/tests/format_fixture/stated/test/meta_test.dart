// States its package through `dart_package_metadata`: 3.6 again.
String describe(String alpha, String beta, String gamma) => '$alpha $gamma';

void main() {
  final _ = 'wildcard';
  final described = describe(
      'the first argument', 'the second argument', 'a variable named $_');
  if (!described.endsWith('wildcard')) {
    throw StateError('expected the wildcard, got: $described');
  }
}
