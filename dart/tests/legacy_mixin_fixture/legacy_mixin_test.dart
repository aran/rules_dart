import 'dart:io';

import 'package:legacy_mixin_fixture_legacy/legacy.dart';
import 'package:legacy_mixin_fixture_mid/mid.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

class _Direct with LegacyMixin, MidMixin {}

class _SubChained extends ChainedLegacy {}

void main(List<String> args) {
  test('modular and whole-program binaries for a legacy-class mixin print the same output', () async {
    final runfiles = Runfiles.create();
    final modularDill = runfiles.rlocation(args[0]);
    final wholeDill = runfiles.rlocation(args[1]);

    final modularRes = await Process.run(Platform.resolvedExecutable, [
      modularDill,
    ]);
    expect(
      modularRes.exitCode,
      0,
      reason: 'modular binary failed: ${modularRes.stderr}',
    );

    final wholeRes = await Process.run(Platform.resolvedExecutable, [
      wholeDill,
    ]);
    expect(
      wholeRes.exitCode,
      0,
      reason: 'whole-program binary failed: ${wholeRes.stderr}',
    );

    final modularOut = (modularRes.stdout as String).replaceAll('\r\n', '\n');
    final wholeOut = (wholeRes.stdout as String).replaceAll('\r\n', '\n');
    expect(modularOut, equals(wholeOut));
    expect(
      modularOut,
      'direct[hello world (legacy:15)]\n'
      'mid[hello chain (legacy:12)]\n',
    );
  });

  test('modular dart_test directly mixing in legacy classes preserves field initializers and member bodies', () {
    final d = _Direct()
      ..bump = 7
      ..prefix = 'test';
    expect(d.tag, 'legacy');
    expect(d.count, 17);
    expect(d.label, 'legacy:17');
    expect(d.decorate(d.greet('direct')), 'test[hello direct (legacy:17)]');

    final c = _SubChained()..bump = 3;
    expect(c.decorate(c.greet('sub')), 'mid[hello sub (legacy:13)]');
  });
}
