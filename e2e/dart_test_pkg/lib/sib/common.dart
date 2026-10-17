import 'package:dart_test_pkg/sib/b.dart';

/// A library listed by two targets that do not depend on each other. It imports
/// `b.dart`, and `b.dart` imports it back, so `sib_b` compiles both as one
/// kernel.
class Common {
  /// The value every `Common` reports.
  int get value => 7;

  /// [bValue] less one, which is [value] again.
  int get next => bValue() - 1;
}
