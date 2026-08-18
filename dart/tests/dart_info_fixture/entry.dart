/// The executable's entrypoint: outside `lib/`, so no `package:` URI reaches it.
import 'package:exec_pkg/owned.dart';

void main() {
  print(ownedMarker);
}
