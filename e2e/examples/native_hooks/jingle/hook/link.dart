// The app's own link hook: of the sounds its build hook routed here, ships
// the one the app's own library names and drops the rest.
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:jingle/jingle.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    output.assets.data.addAll(
      input.assets.data.where((asset) => asset.name == shippedSound),
    );
  });
}
