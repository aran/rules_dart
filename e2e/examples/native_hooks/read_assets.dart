// Opens every file a program ships of what it is handed, as a bundler does,
// from what `program_assets_action_args()` gives it: `--program-assets=<file>`.
//
// Writes `--output`: one line per asset, sorted by id, `<id>=<content>` for a
// data asset and `<id>=` for a code asset. Fails naming an asset whose file is
// not there, or a code asset handed by name that comes with a path.
import 'dart:io';

import 'package:program_assets/program_assets.dart';

void main(List<String> args) {
  String value(String flag) => args
      .firstWhere((a) => a.startsWith('--$flag='))
      .substring(flag.length + 3);
  final assets = ProgramAssets.read(value('program-assets'));
  final lines = <String>[];
  void open(String id, String file, {required bool read}) {
    if (!File(file).existsSync()) {
      stderr.writeln('read_assets: $id is at $file, which is not there');
      exit(1);
    }
    lines.add(read ? '$id=${File(file).readAsStringSync().trim()}' : '$id=');
  }

  if (assets.holdsData) {
    for (final asset in assets.data) {
      open(asset.id, asset.file, read: true);
    }
  }
  final byName = assets.codeView == ProgramCodeView.names;
  for (final asset
      in assets.codeView == null ? const <ProgramCodeAsset>[] : assets.code) {
    if (byName && asset.file != null) {
      stderr.writeln('read_assets: ${asset.id} is handed by name with a path');
      exit(1);
    }
    if (asset.file case final file?) {
      open(asset.id, file, read: false);
    } else {
      lines.add('${asset.id}=');
    }
  }
  lines.sort();
  File(value('output')).writeAsStringSync('${lines.join('\n')}\n');
}
