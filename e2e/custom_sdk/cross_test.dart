import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// `PROGRAM`, a runfiles path, is a 64-bit x86-64 ELF executable.
void main() {
  final path = Runfiles.create().rlocation(Platform.environment['PROGRAM']!);
  final header = File(path).readAsBytesSync().sublist(0, 20);
  const elfMagic = [0x7f, 0x45, 0x4c, 0x46];
  const elfClass64 = 2;
  const machineX8664 = 0x3e;
  final isElf = [for (var i = 0; i < 4; i++) header[i]].join() == elfMagic.join();
  if (!isElf || header[4] != elfClass64 || header[18] != machineX8664) {
    stderr.writeln('$path is not an x86-64 ELF file: $header');
    exit(1);
  }
}
