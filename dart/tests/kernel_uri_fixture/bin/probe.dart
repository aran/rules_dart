// The entrypoint belongs to no package, so the compiler names it by a URI of
// its own choosing, and the binary keeps that URI. It reaches its package's
// `lib/` by `package:` URI, as an entrypoint outside `lib/` must.
import 'dart:io';

import 'package:kernel_uri_fixture/where.dart';

void main() {
  stdout.writeln('product=${const bool.fromEnvironment('dart.vm.product')}');
  stdout.writeln('frame=${callerFrame()}');
}
