import 'dart:ffi';

@Native<Int32 Function()>(
  assetId: 'package:code_asset_config_fixture/which.dart',
  symbol: 'which_configuration',
)
external int whichConfiguration();

/// Fails unless the VM loaded the library its own package declares, which no
/// library in `deps` carries.
void main() {
  final which = whichConfiguration();
  if (which != 1) {
    throw StateError('loaded the library built in configuration $which, not 1');
  }
}
