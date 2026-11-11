import 'package:ping/ping.dart';

/// Steps down to zero through [ping].
int pong(int n) => n <= 0 ? 0 : 1 + ping(n - 1);
