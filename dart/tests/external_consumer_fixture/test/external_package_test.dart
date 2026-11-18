import 'package:fetched_root/generated.dart';
import 'package:fetched_root/hand.dart';
import 'package:fetched_sub/generated.dart';
import 'package:fetched_sub/hand.dart';

void main() {
  final seen = [rootHand, rootGenerated, subHand, subGenerated];
  const want = ['root-hand', 'root-generated', 'sub-hand', 'sub-generated'];
  for (var i = 0; i < want.length; i++) {
    if (seen[i] != want[i]) throw StateError('${seen[i]} != ${want[i]}');
  }
}
