/// Pure-Dart services used by the @StackedApp DI registration in app.dart.
class GreetingService {
  String greet(String name) => 'hello, $name';
}

class CounterService {
  int _count = 0;
  int get count => _count;
  void increment() => _count++;
}
