// Emits every sound as a data asset: to the package's link hook when the
// program is linked, which keeps the ones it uses, and to the app otherwise.
// rules_dart does not run it; `data_assets` on the package's
// `dart_package_metadata` declares what it emits.
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    for (final name in ['bell', 'chime']) {
      output.assets.data.add(
        DataAsset(
          package: input.packageName,
          name: '$name.txt',
          file: input.packageRoot.resolve('assets/$name.txt'),
        ),
        routing: input.config.linkingEnabled
            ? ToLinkHook(input.packageName)
            : const ToAppBundle(),
      );
    }
  });
}
