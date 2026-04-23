import 'package:injectable/injectable.dart';

@injectable
class Greeter {
  String greet(String who) => 'hello, $who';
}
