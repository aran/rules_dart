/// The entrypoint: outside `lib/`, so no `package:` URI reaches it, and it
/// reaches its own package's sources only through the record the constructor
/// puts in the nested `DartInfo`.
import 'package:analyzable_pkg/model.dart';
import 'package:analyzable_pkg/view.dart';

void main() {
  print(describe(const Model('fixture')));
}
