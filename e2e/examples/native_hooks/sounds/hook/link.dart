// Ships the sounds the application uses, out of the ones the build hook
// routed here.
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _sound = Class('Sound', Library('package:sounds/sounds.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final used = {
      for (final use in input.recordedUses?.instances[_sound] ?? const [])
        if (use case InstanceConstantReference(
          instanceConstant: InstanceConstant(
            fields: {'name': StringConstant(value: final name)},
          ),
        ))
          '$name.txt',
    };
    output.assets.data.addAll(
      input.assets.data.where((asset) => used.contains(asset.name)),
    );
  });
}
