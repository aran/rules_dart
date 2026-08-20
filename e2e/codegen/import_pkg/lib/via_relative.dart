// The relative URI is this fixture's point: a hand-written lib file must
// reach its Bazel-generated sibling by adjacency, which only holds if the
// two are staged into one directory. A package: import would resolve through
// package_config and prove nothing.
// ignore: always_use_package_imports
import 'via_relative.g.dart';

/// Uses a Bazel-generated standalone library imported via a relative URI.
String viaRelative() => generatedValue();
