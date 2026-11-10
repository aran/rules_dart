import 'package:hooked/hooked.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await link(args, (input, output) async => answer);
}
