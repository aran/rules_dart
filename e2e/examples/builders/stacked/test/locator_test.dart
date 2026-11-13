import 'package:stacked_fixture/app.locator.dart';
import 'package:stacked_fixture/services.dart';
import 'package:test/test.dart';

void main() {
  test('stacked locator generates DI registrations', () async {
    await setupLocator();
    final greeter = locator<GreetingService>();
    expect(greeter.greet('world'), 'hello, world');

    final counter = locator<CounterService>();
    expect(counter.count, 0);
    counter.increment();
    expect(counter.count, 1);
  });
}
