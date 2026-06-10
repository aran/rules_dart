import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Asserts the aggregate stage received the in-package asset path
/// (`lib/item.shard.json`) for a shard generated in a Bazel package that is
/// a sibling of the Dart package root.
void main() {
  test('sibling-package generated input carries its in-package asset path',
      () {
    final r = Runfiles.create();
    final agg = File(
      r.rlocation('_main/sibling_aggregate_pkg/gen/lib/item.agg.dart'),
    );
    final content = agg.readAsStringSync();
    expect(content, contains('// input-asset: lib/item.dart'));
    expect(content, contains('// extra-asset: lib/item.shard.json'));
    expect(content, contains('// extra-content: shard-for:item.dart'));
  });
}
