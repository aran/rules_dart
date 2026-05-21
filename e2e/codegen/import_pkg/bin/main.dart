import 'package:import_fixture/via_package.dart';
import 'package:import_fixture/via_relative.dart';

void main() {
  print('via_package: ${viaPackage()}');
  print('via_relative: ${viaRelative()}');
}
