import 'package:pong/pong.dart';

String ping(int n) => n == 0 ? 'ping' : 'ping ${pong(n - 1)}';
