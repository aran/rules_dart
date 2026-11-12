// Writes the file a linker reads a shared library's exported symbols from.
//
// The symbols are what a package's `dart_linked_code_asset` tool wrote, one
// per line. The file is the one upstream's `LinkerOptions.treeshake` writes
// for each linker: an ELF version script exporting just them, a Mach-O
// exported-symbols list, or a Windows module-definition file.
//
// Usage:
//   link_exports --format <elf|macho|def> --symbols <file> --output <file>
//       --tool <label>
import 'dart:io';

import 'package:args/args.dart';

void main(List<String> arguments) {
  final args =
      (ArgParser()
            ..addOption(
              'format',
              mandatory: true,
              allowed: ['elf', 'macho', 'def'],
            )
            ..addOption('symbols', mandatory: true)
            ..addOption('output', mandatory: true)
            ..addOption('tool', mandatory: true))
          .parse(arguments);
  final lines = File(args.option('symbols')!)
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final invalid = lines.where((s) => !_symbol.hasMatch(s)).toList();
  if (invalid.isNotEmpty) {
    stderr.writeln(
      '${args.option('tool')} wrote ${invalid.map((s) => '"$s"').join(', ')}, '
      'which ${invalid.length == 1 ? 'is not a symbol name' : 'are not '
                'symbol names'}. It writes one native symbol name per line.',
    );
    exitCode = 1;
    return;
  }
  final symbols = {...lines}.toList()..sort();
  File(args.option('output')!)
      .writeAsStringSync(switch (args.option('format')!) {
        'elf' => [
          '{',
          if (symbols.isNotEmpty) ...[
            '  global:',
            for (final symbol in symbols) '    $symbol;',
          ],
          '  local:',
          '    *;',
          '};',
          '',
        ].join('\n'),
        'macho' => [for (final symbol in symbols) '_$symbol', ''].join('\n'),
        // Exporting nothing, the file is empty, as `cc_binary` passes one so
        // that the linker still writes the import library Bazel declares.
        _ when symbols.isEmpty => '',
        _ => [
          'EXPORTS',
          for (final symbol in symbols) '    $symbol',
          '',
        ].join('\n'),
      });
}

/// A C symbol, or a mangled C++ one.
final _symbol = RegExp(r'^[A-Za-z_.$?@][A-Za-z0-9_.$?@]*$');
