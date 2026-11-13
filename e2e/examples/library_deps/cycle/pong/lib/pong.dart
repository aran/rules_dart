import 'package:ping/ping.dart';

/// Counts down to zero through [ping], one step each.
int pong(int n) => n <= 0 ? 0 : 1 + ping(n - 1);
