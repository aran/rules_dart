import 'package:ping/ping.dart';

String pong(int n) => n == 0 ? 'pong' : 'pong ${ping(n - 1)}';
