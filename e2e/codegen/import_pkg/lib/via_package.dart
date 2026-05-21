import 'package:import_fixture/via_package.g.dart';

/// Uses a Bazel-generated standalone library imported via a `package:` URI.
String viaPackage() => generatedValue();
