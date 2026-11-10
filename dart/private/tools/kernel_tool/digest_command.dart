import 'dart:io';

import 'package:crypto/crypto.dart';

import 'args.dart';

/// `digest`: the SHA-256 of `--input`, in hex, written to `--output`.
///
/// What `dart_test` names the `package:test` runner's cached snapshot by, so
/// that a different runner never starts from a snapshot of another.
Future<int> runDigest(Args args) async {
  final input = File(args.one('input'));
  final digest = sha256.convert(await input.readAsBytes());
  await File(args.one('output')).writeAsString('$digest\n');
  return 0;
}
