import 'package:pong/pong.dart';
import 'package:utils/utils.dart';

/// Counts down to zero through [pong], one step each.
int ping(int n) => n <= 0 ? 0 : 1 + pong(n - 1);

/// [word] as `ping` says it.
String shout(String word) => capitalize(word);
