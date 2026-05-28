// `app_via_facade`'s entrypoint. Imports `package:utils/utils.dart` directly
// (not `package:facade/...` — the facade has no sources to import). Reaches
// `//utils` only through the source-less `//facade` aggregate dep — the
// shape that used to trip `generate_package_config`.
import 'package:utils/utils.dart';

void main() {
  print('facade-mediated: ${capitalize("works")}');
}
