import 'package:dart_test_pkg/split/id.dart';
import 'package:dart_test_pkg/split/role.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'a library whose sources cannot compile alone is compiled by its wrapper',
    () {
      expect(idPath('a'), p.join('ids', 'a'));
      expect(Role.admin.code, 'ADMIN');
      expect(Role.viewer.code, 'VIEWER');
    },
  );
}
