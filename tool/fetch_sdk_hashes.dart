/// Fetches SHA-256 checksums for a Dart SDK release from Google's CDN.
///
/// Usage: dart run tool/fetch_sdk_hashes.dart <version>
///
/// Prints a formatted `versions.bzl` dict entry ready to paste.
/// Uses only dart:io and dart:convert — no pubspec needed.
library;

import 'dart:convert';
import 'dart:io';

const platforms = [
  'macos-arm64',
  'macos-x64',
  'linux-x64',
  'linux-arm64',
  'windows-x64',
];

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/fetch_sdk_hashes.dart <version>');
    stderr.writeln('Example: dart run tool/fetch_sdk_hashes.dart 3.12.0');
    exit(1);
  }

  final version = args[0];
  final hashes = <String, String>{};
  final client = HttpClient();

  try {
    for (final platform in platforms) {
      final hash = await _fetchHash(client, version, platform);
      if (hash == null) {
        stderr.writeln('Failed to fetch hash for $platform');
        exit(1);
      }
      hashes[platform] = hash;
      stderr.writeln('$platform: $hash');
    }
  } finally {
    client.close();
  }

  // Print formatted versions.bzl entry.
  stdout.writeln('    "$version": {');
  for (final platform in platforms) {
    stdout.writeln('        "$platform": "${hashes[platform]}",');
  }
  stdout.writeln('    },');
}

/// Tries the .sha256sum file first; falls back to downloading the zip and
/// computing sha256 locally.
Future<String?> _fetchHash(
  HttpClient client,
  String version,
  String platform,
) async {
  final hash = await _fetchSha256sumFile(client, version, platform);
  if (hash != null) return hash;

  stderr.writeln(
    '  .sha256sum not found for $platform, falling back to full download...',
  );
  return _downloadAndHash(client, version, platform);
}

/// GET the .sha256sum file and parse out the hex hash.
Future<String?> _fetchSha256sumFile(
  HttpClient client,
  String version,
  String platform,
) async {
  final url =
      'https://storage.googleapis.com/dart-archive/channels/stable/release/'
      '$version/sdk/dartsdk-$platform-release.zip.sha256sum';

  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    // Format: "<hash>  <filename>\n" or just "<hash>\n"
    final hash = body.trim().split(RegExp(r'\s+'))[0];
    if (hash.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(hash)) {
      return hash;
    }
    return null;
  } on Exception {
    return null;
  }
}

/// Downloads the full zip and computes SHA-256 locally.
Future<String?> _downloadAndHash(
  HttpClient client,
  String version,
  String platform,
) async {
  final url =
      'https://storage.googleapis.com/dart-archive/channels/stable/release/'
      '$version/sdk/dartsdk-$platform-release.zip';

  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }

    // Stream through sha256 to avoid buffering the entire zip in memory.
    final proc = await Process.start('shasum', ['-a', '256']);
    await response.pipe(proc.stdin);
    final output = await proc.stdout.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode;
    if (exitCode != 0) return null;

    final hash = output.trim().split(RegExp(r'\s+'))[0];
    if (hash.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(hash)) {
      return hash;
    }
    return null;
  } on Exception {
    return null;
  }
}
