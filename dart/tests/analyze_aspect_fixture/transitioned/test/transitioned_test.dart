import 'package:gen_dep/gen.dart';

void main() {
  if (greeting != 'hello') {
    throw StateError('unexpected greeting: $greeting');
  }
}
