import 'package:pong/pong.dart';

/// Counts down to zero through [pong], one step each.
int ping(int n) => n <= 0 ? 0 : 1 + pong(n - 1);
