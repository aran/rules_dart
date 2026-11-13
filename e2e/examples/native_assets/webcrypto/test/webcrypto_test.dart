import 'dart:convert';

import 'package:test/test.dart';
import 'package:webcrypto/webcrypto.dart';

/// Known-answer checks against the Bazel-built BoringSSL behind
/// `package:webcrypto`. Each one crosses into the native library, so a
/// missing or wrongly bound code asset fails here, not at analysis time.
void main() {
  test('SHA-256 of "abc" (FIPS 180-2 B.1)', () async {
    final digest = await Hash.sha256.digestBytes(utf8.encode('abc'));
    expect(
      _hex(digest),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('HMAC-SHA-256 (RFC 4231 test case 2)', () async {
    final key = await HmacSecretKey.importRawKey(
      utf8.encode('Jefe'),
      Hash.sha256,
    );
    final mac = await key.signBytes(
      utf8.encode('what do ya want for nothing?'),
    );
    expect(
      _hex(mac),
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    );
  });

  // Signed outside Dart (openssl, P-256, SHA-256, r||s), the way a passkey
  // assertion arrives: verification must accept it and reject a tampered one.
  test('ECDSA P-256 verifies an externally made signature', () async {
    final key = await EcdsaPublicKey.importRawKey(
      _bytes(
        '04964306831905d1459abf40298444793e138085a84bd6378ab0dc2e965eb399'
        '318fdae4a19e460ea5439e2bb9190cc01f5f19a1c71dc708fec9c4fd5ad1501759',
      ),
      EllipticCurve.p256,
    );
    final signature = _bytes(
      '9a9ba4ff43a87831bd5db9b026a359c634450c630dbd0551e684ac648e64fa47'
      'dadf55ff4e248c414de21007a2e7ee92f3a8b3620de60b54c93b8a62189bf1c0',
    );
    final message = utf8.encode('rules_dart webcrypto');
    expect(await key.verifyBytes(signature, message, Hash.sha256), isTrue);
    signature[0] ^= 1;
    expect(await key.verifyBytes(signature, message, Hash.sha256), isFalse);
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _bytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];
