import 'package:ownpkg/own_util.dart';

void main() {
  if (ownUtil() != 'own-srcs package resolved') {
    throw StateError('package:ownpkg did not resolve to own srcs');
  }
  print('PASS');
}
