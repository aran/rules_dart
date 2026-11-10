@Tags(['suite_tag'])
library;

import 'package:test/test.dart';

/// What `test_runner_test` runs through its launcher to select cases by tag,
/// under targets whose `include_tags`/`exclude_tags` differ. Each case
/// passes, so which ran is read from the report.
void main() {
  test('unit case', () {}, tags: ['unit']);
  test('slow unit case', () {}, tags: ['unit', 'slow']);
  group('integration', () {
    test('case', () {});
  }, tags: ['integration']);
  test('untagged case', () {});
}
