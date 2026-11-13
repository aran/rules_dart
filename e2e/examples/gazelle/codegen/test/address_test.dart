import 'package:codegen/src/model/address.dart';
import 'package:test/test.dart';

void main() {
  test('a generated library in a directory under lib/ builds', () {
    expect(Address(city: 'Oslo').toJson(), {'City': 'Oslo'});
  });
}
