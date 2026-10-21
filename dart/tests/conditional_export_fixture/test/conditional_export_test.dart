import 'package:conditional_export_fixture/init.dart';

void main() {
  if (platform() != 'native') throw StateError(platform());
}
