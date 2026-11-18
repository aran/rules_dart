import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  const base = '_main/dart/tests/external_consumer_fixture';
  for (final (name, files) in [
    (
      'fetched_root',
      {'hand.dart': 'rootHand', 'generated.dart': 'rootGenerated'},
    ),
    ('fetched_sub', {'hand.dart': 'subHand', 'generated.dart': 'subGenerated'}),
  ]) {
    for (final MapEntry(key: file, value: getter) in files.entries) {
      final path = '$base/colocated.$name.pkgsrcs/lib/$file';
      final source = File(runfiles.rlocation(path));
      if (!source.existsSync() || !source.readAsStringSync().contains(getter)) {
        throw StateError('$path has no $getter');
      }
    }
  }
}
