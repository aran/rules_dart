import 'package:path/path.dart' as p;

String greet(String name) {
  final home = p.join('home', name);
  return 'Hello $name, your home is $home';
}
