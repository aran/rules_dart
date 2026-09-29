/// Formatted in the short style that language version 3.6 selects: a wrapped
/// argument list indented four spaces, with no trailing comma. From 3.7 on the
/// formatter uses the tall style and would put each argument on its own line,
/// so this file is a violation at every later version — which is the point of
/// the fixture.
String describeMeasurement(String alpha, String beta, String gamma) => alpha;

String describe() {
  return describeMeasurement(
      'the first argument', 'the second argument', 'the third one');
}
