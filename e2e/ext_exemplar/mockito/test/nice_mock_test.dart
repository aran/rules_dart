import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito_fixture/clock.dart';
import 'package:test/test.dart';

import 'nice_mock_test.mocks.dart';

// Exercises the newer `@GenerateNiceMocks` API (mockito 5.x). Two MockSpecs:
//
//   1. Default MockSpec<Clock> — nice-mock behavior (no-throw on unstubbed
//      calls) comes from `@GenerateNiceMocks`, with the mock class named
//      `MockClock` by convention.
//   2. MockSpec<Clock>(as: #NamedClock, onMissingStub:
//      OnMissingStub.returnDefault) — the `as:` override renames the
//      generated mock, and `returnDefault` makes unstubbed calls return
//      typed zero values (0, '', null) instead of the default
//      `throwOnMissingStub` semantics. Both behaviors are observable at
//      runtime and guarded here.
@GenerateNiceMocks([
  MockSpec<Clock>(),
  MockSpec<Clock>(
    as: #NamedClock,
    onMissingStub: OnMissingStub.returnDefault,
  ),
])
void main() {
  group('@GenerateNiceMocks — default MockSpec<Clock>', () {
    test('mock class is generated as MockClock', () {
      final mock = MockClock();
      expect(mock, isA<Clock>());
    });

    test('stubbed methods return stubbed values; verify().called(n) works',
        () {
      final mock = MockClock();
      final fixedNow = DateTime.utc(2024, 1, 2);
      when(mock.now()).thenReturn(fixedNow);

      expect(mock.now(), equals(fixedNow));
      expect(mock.now(), equals(fixedNow));
      verify(mock.now()).called(2);
    });

    test('unstubbed methods on a default nice mock return typed zero values',
        () {
      // Default @GenerateNiceMocks contract: calling an unstubbed method
      // returns the type's zero value rather than throwing — the reason
      // the API is "nice".
      final mock = MockClock();
      expect(mock.millisSince(DateTime.utc(2024)), equals(0));
    });
  });

  group('@GenerateNiceMocks — MockSpec(as: #NamedClock, returnDefault)', () {
    test('custom `as:` produces a distinct generated class name', () {
      final n = NamedClock();
      expect(n, isA<Clock>());
      expect(n, isNot(isA<MockClock>()));
    });

    test('OnMissingStub.returnDefault returns typed zero values', () {
      final n = NamedClock();
      // DateTime has no natural "zero" — mockito's `returnDefault` returns
      // DateTime(0) (Unix epoch). int returns 0.
      expect(n.millisSince(DateTime.utc(2024)), equals(0));
      final d = n.now();
      expect(d, isA<DateTime>());
    });

    test('stubbing still wins over returnDefault', () {
      final n = NamedClock();
      when(n.millisSince(any)).thenReturn(999);
      expect(n.millisSince(DateTime.utc(2024)), equals(999));
      verify(n.millisSince(any)).called(1);
    });
  });
}
