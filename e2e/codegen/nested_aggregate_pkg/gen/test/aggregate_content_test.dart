import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Asserts the aggregate stage received the in-package asset path
/// (`lib/item.shard.json`) for the generated shard — not a path polluted by
/// the nested Bazel package (`gen/nested_aggregate_pkg/lib/...`).
void main() {
  test('generated aggregate input carries its in-package asset path', () {
    final r = Runfiles.create();
    final agg = File(
      r.rlocation('_main/nested_aggregate_pkg/gen/lib/item.agg.dart'),
    );
    final content = agg.readAsStringSync();
    expect(content, contains('// input-asset: lib/item.dart'));
    expect(content, contains('// extra-asset: lib/item.shard.json'));
    expect(content, contains('// extra-content: shard-for:item.dart'));
  });
}
