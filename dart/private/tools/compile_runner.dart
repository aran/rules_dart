// Build-action runner for `dart compile exe` and `dart compile aot-snapshot`
// on macOS: compiles, then removes the one thing in the output that depends on
// where it was compiled.
//
// gen_snapshot writes the path of the snapshot it produces into the Mach-O
// symbol table, as an N_OSO debug-map entry (dart-lang/sdk#64547). For
// `aot-snapshot` that is the absolute output path, so it names the output base;
// `exe` writes its snapshot under a new temporary directory each time, so two
// builds from the same inputs never match. The entry points at a file that is
// gone or elsewhere by the time anything reads it.
//
// The compile writes into a directory whose path has the same length on every
// machine, which fixes the size of the string table. The entry's string is then
// replaced by its file name, and the ad-hoc code signatures over the pages that
// changed are recomputed: the embedded snapshot's own, then the executable's.
//
// This works around a gen_snapshot bug, fixed upstream by dart-lang/sdk
// e2c6325 ("[vm] Fix stripping of Mach-O snapshots"), which 3.13.7 predates.
// Once a stable SDK carries it, gen_snapshot's `--strip` should leave no path
// behind; then this runner and `dart_bootstrap_binary` are deleted and the
// compile passes `--strip` instead (docs/CHORES.md, Dart SDK Version Bump).
//
// Usage: compile_runner --output <file> -- <dart> compile <mode> ... <kernel>
// The runner appends `-o`.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

void main(List<String> args) {
  final split = args.indexOf('--');
  if (split != 2 || args[0] != '--output' || split + 1 >= args.length) {
    stderr.writeln(
      'compile_runner: usage: --output <file> -- <dart> compile <mode> ...',
    );
    exit(64);
  }
  final output = args[1];
  final command = args.sublist(split + 1);

  // Under `/tmp`, the same path on every machine: the system temporary
  // directory is per user, and an action's environment can set it to anything.
  final scratch = Directory('/tmp').createTempSync('rules_dart_compile_');
  try {
    final compiled = '${scratch.path}/${output.split('/').last}';
    final result = Process.runSync(
      command.first,
      [...command.skip(1), '-o', compiled],
      // Where `exe` puts its intermediate snapshot.
      environment: {'TMPDIR': scratch.path},
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      exitCode = result.exitCode;
      return;
    }

    final file = File(compiled);
    final bytes = file.readAsBytesSync();
    normalize(bytes);
    file.writeAsBytesSync(bytes);
    // A copy keeps the executable bit; a rename can cross file systems.
    file.copySync(output);
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

const _mhMagic64 = 0xfeedfacf;
const _lcSymtab = 0x2;
const _lcCodeSignature = 0x1d;
const _lcNote = 0x31;
const _nOso = 0x66;
const _snapshotNoteOwner = '__dart_app_snap';
const _csMagicEmbeddedSignature = 0xfade0cc0;
const _csMagicCodeDirectory = 0xfade0c02;

/// Rewrites, in place, every N_OSO entry in the Mach-O image [bytes] and in
/// the snapshot an `exe` embeds, and re-signs what it changed. Leaves anything
/// that is not a 64-bit Mach-O as it is.
void normalize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (data.lengthInBytes < 32 ||
      data.getUint32(0, Endian.little) != _mhMagic64) {
    return;
  }
  _normalizeImage(bytes, 0);
}

/// Normalizes the image at [base], returning the byte ranges it changed.
List<(int, int)> _normalizeImage(Uint8List bytes, int base) {
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(base, Endian.little) != _mhMagic64) {
    throw FormatException('compile_runner: no Mach-O image at $base');
  }
  final changed = <(int, int)>[];
  int? signature;
  var at = base + 32;
  for (var i = data.getUint32(base + 16, Endian.little); i > 0; i--) {
    final cmd = data.getUint32(at, Endian.little);
    switch (cmd) {
      case _lcSymtab:
        changed.addAll(
          _rewriteOso(
            bytes,
            base + data.getUint32(at + 8, Endian.little),
            data.getUint32(at + 12, Endian.little),
            base + data.getUint32(at + 16, Endian.little),
          ),
        );
      case _lcNote:
        final owner = String.fromCharCodes(
          bytes.sublist(at + 8, at + 24).takeWhile((c) => c != 0),
        );
        if (owner == _snapshotNoteOwner) {
          changed.addAll(
            _normalizeImage(
              bytes,
              base + data.getUint64(at + 24, Endian.little),
            ),
          );
        }
      case _lcCodeSignature:
        signature = base + data.getUint32(at + 8, Endian.little);
    }
    at += data.getUint32(at + 4, Endian.little);
  }
  if (signature != null && changed.isNotEmpty) {
    changed.addAll(_resign(bytes, base, signature, changed));
  }
  return changed;
}

/// Replaces each N_OSO string with its last path component, padded with NULs
/// to its old length.
List<(int, int)> _rewriteOso(
  Uint8List bytes,
  int symbols,
  int count,
  int strings,
) {
  final data = ByteData.sublistView(bytes);
  final changed = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    final entry = symbols + i * 16;
    if (bytes[entry + 4] != _nOso) continue;
    final start = strings + data.getUint32(entry, Endian.little);
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    final path = String.fromCharCodes(bytes.sublist(start, end));
    final name = path.split('/').last.codeUnits;
    bytes.fillRange(start, end, 0);
    bytes.setRange(start, start + name.length, name);
    changed.add((start, end));
  }
  return changed;
}

/// Recomputes, in every code directory of the signature at [signature], the
/// hashes of the pages of the image at [base] that [changed] touches.
List<(int, int)> _resign(
  Uint8List bytes,
  int base,
  int signature,
  List<(int, int)> changed,
) {
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(signature) != _csMagicEmbeddedSignature) {
    throw FormatException('compile_runner: no code signature at $signature');
  }
  final rehashed = <(int, int)>[];
  for (var i = 0; i < data.getUint32(signature + 8); i++) {
    final cd = signature + data.getUint32(signature + 12 + i * 8 + 4);
    if (data.getUint32(cd) != _csMagicCodeDirectory) continue;
    final version = data.getUint32(cd + 8);
    final hashOffset = data.getUint32(cd + 16);
    var codeLimit = data.getUint32(cd + 32);
    if (codeLimit == 0 && version >= 0x20300) {
      codeLimit = data.getUint64(cd + 56);
    }
    final hashSize = bytes[cd + 36];
    final hash = switch (bytes[cd + 37]) {
      1 => sha1,
      2 || 3 => sha256,
      final type => throw FormatException(
        'compile_runner: unsupported code signature hash type $type',
      ),
    };
    final pageShift = bytes[cd + 39];
    final pageSize = pageShift == 0 ? codeLimit : 1 << pageShift;
    final pages = <int>{
      for (final (start, end) in changed)
        if (start - base < codeLimit)
          for (
            var page = (start - base) ~/ pageSize;
            page <= (end - 1 - base) ~/ pageSize && page * pageSize < codeLimit;
            page++
          )
            page,
    };
    for (final page in pages) {
      final from = base + page * pageSize;
      final to = base + ((page + 1) * pageSize).clamp(0, codeLimit);
      final digest = hash.convert(Uint8List.sublistView(bytes, from, to)).bytes;
      final slot = cd + hashOffset + page * hashSize;
      bytes.setRange(slot, slot + hashSize, digest);
      rehashed.add((slot, slot + hashSize));
    }
  }
  return rehashed;
}
