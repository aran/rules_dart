import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

/// Verifies the cross-compiled binary is an ELF executable (Linux), not
/// Mach-O (macOS). On Linux hosts this is a no-op (native build produces
/// ELF anyway), but on macOS hosts it validates actual cross-compilation.
void main() {
  final r = Runfiles.create();
  final binaryPath = r.rlocation('_main/app_linux_x64');

  final file = File(binaryPath);
  if (!file.existsSync()) {
    stderr.writeln('FAIL: binary not found at $binaryPath');
    exit(1);
  }

  // ELF magic: 0x7f 'E' 'L' 'F'
  final Uint8List header = file.openSync().readSync(4);
  final isElf = header.length == 4 &&
      header[0] == 0x7f &&
      header[1] == 0x45 && // 'E'
      header[2] == 0x4c && // 'L'
      header[3] == 0x46; // 'F'

  if (isElf) {
    print('PASS: binary is ELF (Linux)');
  } else {
    stderr.writeln(
      'FAIL: expected ELF binary, got magic bytes: '
      '${header.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}',
    );
    exit(1);
  }
}
