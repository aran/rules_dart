import 'package:lib/greeter.dart' deferred as g;

void main() async {
  await g.loadLibrary();
  print(g.greet('Deferred'));
}
