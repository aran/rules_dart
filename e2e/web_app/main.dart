import 'package:characters/characters.dart';
import 'package:greet/greet.dart';
import 'package:web_app/root_greet.dart';
import 'config.dart';

void main() {
  print('$appName v$appVersion');
  print(greet('JavaScript'));
  print(rootGreet());
  print(const String.fromEnvironment('banner'));
  print('flag count: ${'🇨🇦'.characters.length}');
}
