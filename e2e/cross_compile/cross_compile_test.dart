import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// Verifies each cross-compiled binary was built for the architecture its
/// `--platforms` asked for, by reading the ELF identification header.
///
/// The predecessor of this test read only the 4-byte ELF magic, which cannot
/// tell architectures apart: an x86-64, AArch64, RISC-V and ARM binary all pass
/// it identically, as would a miswired toolchain that silently emitted host
/// architecture for every target. `e_machine` is the field that distinguishes
/// them, and `EI_CLASS` is what proves the 32-bit ARMv7 target is really 32-bit.
///
/// Known limit: `e_machine` is `EM_ARM` for both ARMv7 and ARMv6, so the armv7
/// claim rests on Dart's documented `linux-arm` target being armv7 hardfloat,
/// not on this check. `e_flags` would distinguish them but is not reliably
/// populated across both compile modes.
///
/// Values verified against `dart compile` output for both `exe` and
/// `aot-snapshot`; `e_machine` and `EI_CLASS` are identical across the two
/// modes, so one table covers all eight artifacts.

/// ELF `e_machine` values (offset 0x12, u16 little-endian).
const _emX8664 = 0x3E;
const _emAarch64 = 0xB7;
const _emRiscv = 0xF3;
const _emArm = 0x28;

/// ELF `EI_CLASS` values (offset 4).
const _elf32 = 1;
const _elf64 = 2;

class _Expectation {
  const _Expectation(this.elfClass, this.machine, this.label);

  final int elfClass;
  final int machine;
  final String label;
}

/// Keyed by the `--platforms` target name shared by the `exe` and `aot` pair.
const _targets = <String, _Expectation>{
  'linux_x64': _Expectation(_elf64, _emX8664, 'x86-64'),
  'linux_arm64': _Expectation(_elf64, _emAarch64, 'AArch64'),
  'linux_riscv64': _Expectation(_elf64, _emRiscv, 'RISC-V'),
  'linux_arm': _Expectation(_elf32, _emArm, 'ARM (armv7)'),
};

String _hex(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';

void main() {
  final r = Runfiles.create();
  final failures = <String>[];

  // Collected so we can assert the four architectures are pairwise distinct.
  final seenMachines = <String, int>{};

  for (final entry in _targets.entries) {
    final target = entry.key;
    final want = entry.value;

    for (final prefix in const ['app', 'app_aot']) {
      final name = '${prefix}_$target';
      final path = r.rlocation('_main/$name');
      final file = File(path);

      if (!file.existsSync()) {
        failures.add('$name: not found at $path (missing from `data`?)');
        continue;
      }

      // 20 bytes covers e_ident (16) through e_machine (0x12..0x13).
      final Uint8List header = file.openSync().readSync(20);
      if (header.length < 20) {
        failures.add('$name: only ${header.length} bytes, not an ELF header');
        continue;
      }

      if (header[0] != 0x7f ||
          header[1] != 0x45 || // 'E'
          header[2] != 0x4c || // 'L'
          header[3] != 0x46) {
        // 'F'
        failures.add(
          '$name: not ELF — magic ${header.take(4).map(_hex).join(' ')} '
          '(Mach-O or PE means the target OS was ignored)',
        );
        continue;
      }

      if (header[4] != want.elfClass) {
        failures.add(
          '$name: EI_CLASS ${header[4]}, want ${want.elfClass} '
          '(${want.elfClass == _elf32 ? '32' : '64'}-bit for ${want.label})',
        );
      }

      // EI_DATA must be little-endian for the u16 read below to be sound.
      if (header[5] != 1) {
        failures.add('$name: EI_DATA ${header[5]}, want 1 (little-endian)');
        continue;
      }

      final machine = header[0x12] | (header[0x13] << 8);
      if (machine != want.machine) {
        failures.add(
          '$name: e_machine ${_hex(machine)}, want ${_hex(want.machine)} '
          '(${want.label}) — built for the wrong architecture',
        );
      }
      seenMachines['$name'] = machine;
    }
  }

  // The original bug was a check that could not tell architectures apart. If a
  // miswiring made every output host-architecture, this fails even if someone
  // later loosens the table above.
  final distinct = _targets.keys
      .map((t) => seenMachines['app_$t'])
      .where((m) => m != null)
      .toSet();
  if (seenMachines.isNotEmpty && distinct.length != _targets.length) {
    failures.add(
      'expected ${_targets.length} distinct e_machine values across targets, '
      'got ${distinct.length} (${distinct.map((m) => _hex(m!)).join(', ')}) — '
      'targets are collapsing to the same architecture',
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('FAIL: ${failures.length} problem(s):');
    for (final f in failures) {
      stderr.writeln('  - $f');
    }
    exit(1);
  }

  print('PASS: ${seenMachines.length} binaries, each ELF for its target '
      'architecture (${_targets.values.map((e) => e.label).join(', ')})');
}
