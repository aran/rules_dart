import 'package:external_builder/person.dart';
import 'package:test/test.dart';

void main() {
  test('the external builder wrote the greeting', () {
    expect(greetPerson(), 'Hello, Person');
  });
}
