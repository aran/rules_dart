// Each fetched package says what it is, for any SBOM tool: the purls in the
// package metadata of the closure are exactly the expected ones.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

String _purl(Runfiles runfiles, String path) {
  final metadata = jsonDecode(
    File(runfiles.rlocation(path)).readAsStringSync(),
  );
  return (metadata as Map<String, Object?>)['purl']! as String;
}

void main() {
  final runfiles = Runfiles.create();
  final env = Platform.environment;
  final got = [
    for (final path in env['PACKAGE_METADATA']!.split(' '))
      _purl(runfiles, path),
  ]..sort();
  final want = env['PURLS']!.split(' ')..sort();
  // The SDK's archive, and so its purl's digest and URL, differs by host.
  final sdk = env['SDK_PURL_PREFIX'] ?? '';
  bool isSdk(String purl) => sdk.isNotEmpty && purl.startsWith(sdk);
  final rest = got.where((p) => !isSdk(p)).join(' ');
  final sdkCount = got.where(isSdk).length;
  if (rest != want.join(' ') || sdkCount != (sdk.isEmpty ? 0 : 1)) {
    final also = sdk.isEmpty ? '' : ', and one starting $sdk';
    stderr.writeln('purls:\n  got  $got\n  want $want$also');
    exit(1);
  }
}
