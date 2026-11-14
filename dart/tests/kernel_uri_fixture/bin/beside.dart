// `probe.dart`, beside a file the build generates, imported by a relative path.
import 'dart:io';

import 'package:kernel_uri_fixture/where.dart';

import 'generated.dart';

void main() {
  stdout.writeln('product=${const bool.fromEnvironment('dart.vm.product')}');
  stdout.writeln('generated=$generated');
  stdout.writeln('frame=${callerFrame()}');
}
