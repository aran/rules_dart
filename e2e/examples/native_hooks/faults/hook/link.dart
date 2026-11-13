// Emits the promised asset and commits the fault each recorded `Fault` names.
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _fault = Class('Fault', Library('package:faults/faults.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final faults = {
      for (final use in input.recordedUses?.instances[_fault] ?? const [])
        if (use case InstanceConstantReference(
          instanceConstant: InstanceConstant(
            fields: {'kind': StringConstant(value: final kind)},
          ),
        ))
          kind,
    };
    final file = File.fromUri(input.outputDirectory.resolve('fault.txt'))
      ..writeAsStringSync('fault\n');
    DataAsset asset(String name, {String? package}) => DataAsset(
      package: package ?? input.packageName,
      name: name,
      file: file.uri,
    );
    if (!faults.contains('unpromised')) {
      output.assets.data.add(asset('promised.txt'));
    }
    if (faults.contains('foreign')) {
      output.assets.data.add(asset('foreign.txt', package: 'glyphs'));
    }
    if (faults.contains('twice')) {
      output.assets.data
        ..add(asset('twice.txt'))
        ..add(asset('twice.txt'));
    }
    if (faults.contains('escape')) {
      output.assets.data.add(asset('../escape.txt'));
    }
    if (faults.contains('case')) {
      output.assets.data
        ..add(asset('Case.txt'))
        ..add(asset('case.txt'));
    }
    if (faults.contains('prefix')) {
      output.assets.data
        ..add(asset('dir'))
        ..add(asset('dir/inner.txt'));
    }
    if (faults.contains('route')) {
      output.assets.data.add(
        asset('routed.txt'),
        routing: const ToLinkHook('glyphs'),
      );
    }
  });
}
