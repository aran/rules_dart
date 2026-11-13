import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito_fixture/api.dart';
import 'package:test/test.dart';

import 'api_test.mocks.dart';

@GenerateMocks([Api])
void main() {
  test('mockito mock records calls', () async {
    final mock = MockApi();
    when(mock.fetch('answer')).thenAnswer((_) async => '42');
    expect(await mock.fetch('answer'), '42');
    verify(mock.fetch('answer')).called(1);
  });
}
