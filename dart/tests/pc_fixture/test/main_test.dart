import 'package:pc_own_srcs_fixture/util.dart';

void main() {
  if (pcUtil() != 'from own srcs') {
    throw StateError('unexpected util output');
  }
}
