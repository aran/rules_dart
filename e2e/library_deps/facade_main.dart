// `app_via_facade`'s entrypoint. Imports `package:utils/utils.dart` directly
// (not `package:facade/...` — the facade has no sources to import). Reaches
// `//utils` only through the source-less `//facade` aggregate dep.

import 'dart:io';

import 'package:utils/utils.dart';

void main() {
  stdout.writeln('facade-mediated: ${capitalize("works")}');
}
