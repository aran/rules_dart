/// Deliberately beside `lib/` rather than inside it. No `package:` URI can
/// reach this file, which is what the accompanying test asserts.
String stray() => 'stray';
