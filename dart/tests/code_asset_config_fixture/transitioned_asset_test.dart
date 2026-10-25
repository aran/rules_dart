import 'dart:ffi';

@Native<Int32 Function()>(
  assetId: 'package:code_asset_config_fixture/which.dart',
  symbol: 'which_configuration',
)
external int whichConfiguration();

/// Fails unless the VM loaded the library the asset names, built in the
/// transitioned configuration, rather than the same-named library the test's
/// own configuration also builds.
void main() {
  final which = whichConfiguration();
  if (which != 2) {
    throw StateError('loaded the library built in configuration $which, not 2');
  }
}
