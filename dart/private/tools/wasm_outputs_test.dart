import 'package:test/test.dart';

import 'wasm_outputs.dart';

void main() {
  const map = 'bazel-out/k8-fastbuild/bin/app.wasm.map';

  test('a source under the map is relative to its directory', () {
    expect(
      relativizeSource(
        'execroot:///bazel-out/k8-fastbuild/bin/app.proj/src/main.dart',
        map,
      ),
      'app.proj/src/main.dart',
    );
  });

  test('a source outside the map climbs out of its directory', () {
    expect(
      relativizeSource('execroot:///external/pkg+/lib/a.dart', map),
      '../../../external/pkg+/lib/a.dart',
    );
    expect(
      relativizeSource('execroot:///greet/lib/g.dart', map),
      '../../../greet/lib/g.dart',
    );
  });

  test(
    'a source beside the map in another configuration shares only the root',
    () {
      expect(
        relativizeSource('execroot:///bazel-out/other/bin/x/y.dart', map),
        '../../other/bin/x/y.dart',
      );
    },
  );

  test('other URIs are left as they are', () {
    expect(
      relativizeSource('org-dartlang-sdk:///lib/core/print.dart', map),
      'org-dartlang-sdk:///lib/core/print.dart',
    );
  });

  test('the rest of the map is kept', () {
    final out = relativizeMap(
      '{"version":3,"sources":["execroot:///bazel-out/k8-fastbuild/bin/m.dart"],"mappings":"AAAA"}',
      map,
    );
    expect(out, '{"version":3,"sources":["m.dart"],"mappings":"AAAA"}');
  });
}
