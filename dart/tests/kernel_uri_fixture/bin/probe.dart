// The entrypoint belongs to no package, so the compiler names it by a URI of
// its own choosing, and the binary keeps that URI. It reaches its package's
// `lib/` by `package:` URI, as an entrypoint outside `lib/` must.
import 'package:kernel_uri_fixture/where.dart';

void main() {
  print('product=${const bool.fromEnvironment('dart.vm.product')}');
  print('frame=${callerFrame()}');
}
