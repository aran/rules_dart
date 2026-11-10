import 'member.dart';

/// A plain library and an annotated one importing each other, as one Dart
/// package's libraries may: the package is one `dart_library`, so the cycle
/// builds.
String greet(Member member) => 'Hello, ${member.name}';
