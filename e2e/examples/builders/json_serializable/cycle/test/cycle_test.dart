import 'package:customer/customer.dart';
import 'package:order/order.dart';
import 'package:test/test.dart';

void main() {
  test('each package serializes what it takes from the other', () {
    final order = Order.fromJson({
      'id': 'o1',
      'customer': {
        'name': 'Ada',
        'orderIds': ['o1'],
      },
    });
    expect(order.customer.name, 'Ada');
    expect(order.customer.placed(order), isTrue);
    expect(order.toJson()['customer'], isA<Customer>());
    expect(order.customer.toJson(), {
      'name': 'Ada',
      'orderIds': ['o1'],
    });
  });
}
