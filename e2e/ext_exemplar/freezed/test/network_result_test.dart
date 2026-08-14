import 'package:freezed_fixture/network_result.dart';
import 'package:test/test.dart';

void main() {
  group('freezed union: NetworkResult<T>', () {
    test('.when dispatches to the matching variant', () {
      String describe(NetworkResult<int> r) => r.when(
            success: (data) => 'ok:$data',
            failure: (code, message) => 'err:$code:$message',
            loading: () => 'loading',
          );

      expect(describe(const NetworkResult.success(42)), 'ok:42');
      expect(
        describe(const NetworkResult.failure(code: 500, message: 'boom')),
        'err:500:boom',
      );
      expect(describe(const NetworkResult<int>.loading()), 'loading');
    });

    test('.map dispatches on the variant constructor', () {
      const r = NetworkResult<String>.success('hello');
      final label = r.map(
        success: (s) => 'success(${s.data})',
        failure: (f) => 'failure',
        loading: (l) => 'loading',
      );
      expect(label, 'success(hello)');
    });

    test('.maybeWhen falls back to orElse for unhandled variants', () {
      String describe(NetworkResult<int> r) => r.maybeWhen(
            success: (data) => 'ok:$data',
            orElse: () => 'other',
          );

      expect(describe(const NetworkResult.success(7)), 'ok:7');
      expect(describe(const NetworkResult<int>.loading()), 'other');
      expect(
        describe(const NetworkResult.failure(code: 404, message: 'nf')),
        'other',
      );
    });

    test('@Default applies when the field is omitted at construction', () {
      const f = NetworkResult<int>.failure(code: 400);
      // The failure variant can be pattern-matched to read its fields.
      final msg = f.when(
        success: (_) => fail('expected failure'),
        failure: (_, message) => message,
        loading: () => fail('expected failure'),
      );
      expect(msg, '');
    });

    test('copyWith on a specific variant preserves type and updates fields',
        () {
      const s = NetworkResult<String>.success('a');
      // Via the variant-specific class you can copyWith fields of that
      // variant — freezed generates the per-variant copyWith extension.
      final s2 = (s as NetworkSuccess<String>).copyWith(data: 'b');
      expect(s2.data, 'b');
      expect(s2, isA<NetworkSuccess<String>>());
    });

    test('variants implement value equality', () {
      expect(
        const NetworkResult<int>.success(1),
        equals(const NetworkResult<int>.success(1)),
      );
      expect(
        const NetworkResult<int>.success(1),
        isNot(equals(const NetworkResult<int>.success(2))),
      );
      expect(
        const NetworkResult<int>.loading(),
        equals(const NetworkResult<int>.loading()),
      );
    });
  });
}
