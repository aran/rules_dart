// An executable's entrypoint in the 3.6 package: short style, like lib/.
import 'package:short/short.dart';

void main() {
  print(describeMeasurement(
      'the first argument', 'the second argument', describe()));
}
