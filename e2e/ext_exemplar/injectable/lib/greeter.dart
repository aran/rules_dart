import 'package:injectable/injectable.dart';

/// A factory-registered service.
@injectable
class Greeter {
  /// Greets [who].
  String greet(String who) => 'hello, $who';
}
