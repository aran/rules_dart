// The entrypoint half of the fixture: a `main` beside `lib/` rather than
// inside it, which is exactly the shape `dart_library` refuses and therefore
// the shape that could not be analyzed before `DartAnalyzableInfo`.
import 'package:analyzable_dep/dep.dart';

void main() {
  print(greeting());
}
