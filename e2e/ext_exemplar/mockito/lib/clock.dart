// Interface used by `test/nice_mock_test.dart` to exercise
// `@GenerateNiceMocks`, `MockSpec(as: ...)`, and `OnMissingStub.returnDefault`.
abstract class Clock {
  DateTime now();
  int millisSince(DateTime start);
}
