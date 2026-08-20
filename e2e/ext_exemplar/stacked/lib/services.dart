/// Pure-Dart services used by the @StackedApp DI registration in app.dart.
class GreetingService {
  /// Greets [name].
  String greet(String name) => 'hello, $name';
}

/// A counter service registered as a lazy singleton.
class CounterService {
  int _count = 0;

  /// The current count.
  int get count => _count;

  /// Increments the count.
  void increment() => _count++;
}
