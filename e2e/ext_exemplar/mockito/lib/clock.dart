/// Interface used by `test/nice_mock_test.dart` to exercise
/// `@GenerateNiceMocks`, `MockSpec(as: ...)`, and
/// `OnMissingStub.returnDefault`.
abstract class Clock {
  /// The current time.
  DateTime now();

  /// Milliseconds elapsed since [start].
  int millisSince(DateTime start);
}
