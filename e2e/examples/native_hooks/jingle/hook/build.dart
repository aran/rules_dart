// Emits the app's sounds as data assets: to the app's own link hook when it
// is linked, and to the bundle otherwise. rules_dart does not run it;
// `data_assets` on the package's `dart_package_metadata` declares what it
// emits.
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    for (final name in ['hum', 'tune']) {
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
