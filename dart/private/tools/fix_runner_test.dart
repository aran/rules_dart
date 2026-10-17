import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'fix_runner.dart' as fix_runner;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fix_runner_test_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('repointPackageConfig emits only relative rootUris for sibling and nested scratch dirs', () {
    final project = Directory('${tmp.path}/pkg/demo.proj')
      ..createSync(recursive: true);
    final extPkg = Directory('${tmp.path}/pkg/demo.extpkgs/foo')
      ..createSync(recursive: true);
    final repoPkg = Directory('${tmp.path}/external/rules_dart++pub+bar')
      ..createSync(recursive: true);
    Directory('${project.path}/pkgs/sub').createSync(recursive: true);

    const initialConfig = {
      'configVersion': 2,
      'packages': [
        {'name': 'demo', 'rootUri': '..', 'packageUri': 'lib/'},
        {'name': 'sub', 'rootUri': '../pkgs/sub', 'packageUri': 'lib/'},
        {
          'name': 'foo',
          'rootUri': '../../demo.extpkgs/foo',
          'packageUri': 'lib/',
        },
        {
          'name': 'bar',
          'rootUri': '../../../external/rules_dart++pub+bar',
          'packageUri': 'lib/',
        },
      ],
    };

    for (final scratchRel in ['pkg/demo.scratch', 'deep/nested/scratch']) {
      final scratch = Directory('${tmp.path}/$scratchRel');
      final configFile = File('${scratch.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(initialConfig)}\n',
        );

      fix_runner.repointPackageConfig(project.path, scratch.path);

      final raw = configFile.readAsStringSync();
      expect(raw, isNot(contains('file:')));
      expect(raw, isNot(contains(tmp.path)));

      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final packages = {
        for (final p in (decoded['packages'] as List).cast<Map>())
          p['name'] as String: p['rootUri'] as String,
      };

      for (final uri in packages.values) {
        expect(Uri.parse(uri).hasScheme, isFalse);
        expect(uri.startsWith('/'), isFalse);
      }

      expect(packages['demo'], '..');
      expect(packages['sub'], '../pkgs/sub');

      final scratchConfigDir = Uri.directory(
        Directory('${scratch.path}/.dart_tool').absolute.path,
      );
      expect(
        scratchConfigDir.resolveUri(Uri.parse('${packages['foo']}/')),
        Uri.directory(extPkg.absolute.path),
      );
      expect(
        scratchConfigDir.resolveUri(Uri.parse('${packages['bar']}/')),
        Uri.directory(repoPkg.absolute.path),
      );
    }
  });
}
