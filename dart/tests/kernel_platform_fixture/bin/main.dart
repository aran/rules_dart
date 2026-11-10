import 'package:kernel_platform_fixture/greet.dart';

// No `dart:io`: the kernel is compared byte for byte across platforms.
// ignore: avoid_print
void main() => print(greet('main'));
