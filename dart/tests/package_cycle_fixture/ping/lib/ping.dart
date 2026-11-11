import 'package:pong/pong.dart';

/// Steps down to zero through [pong].
int ping(int n) => n <= 0 ? 0 : 1 + pong(n - 1);
