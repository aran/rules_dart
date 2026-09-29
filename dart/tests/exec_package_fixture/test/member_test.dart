import 'package:exec_pkg/exec_pkg.dart';

void main() {
  if (greeting() != 'hello') throw StateError('unexpected greeting');
}
