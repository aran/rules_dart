// An entrypoint inside the package, compiled as its `package:` URI.
import 'greet.dart';

// No `dart:io`: the kernel is compared byte for byte across platforms.
// ignore: avoid_print
void main() => print(greet('app'));
