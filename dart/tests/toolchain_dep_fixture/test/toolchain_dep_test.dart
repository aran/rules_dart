import 'package:toolchain_dep_fixture/uses_runtime.dart';

void main() {
  if (usesRuntime() != 'uses runtime inner and inner') {
    throw StateError(usesRuntime());
  }
}
