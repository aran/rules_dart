/// Reading what a Dart program ships: its data and code assets, as rules_dart's
/// program-assets operation (`DartProgramAssetsInfo`) decides them.
///
/// A tool receives them as one file, in the program-assets line format: an
/// action's tool as the param file `program_assets_action_args()` gives it
/// (`--program-assets=<file>`), a test or program as the `<name>.program_assets`
/// of a `dart_program_assets` target in its runfiles. [ProgramAssets.read]
/// reads either into the assets that ship, with each link hook's output
/// directory listed and its code selection applied. The README documents the
/// format, for tools that are not written in Dart; this library is its
/// reference reader.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// The first two lines of every file in the format: its name and version.
const programAssetsFormat = 'rules_dart_program_assets/1';

/// What a file holds of a program's code assets.
enum ProgramCodeView {
  /// Each code asset with its library: what a bundler of them reads.
  libraries,

  /// Each code asset's id, link mode, library file name and uri, without
  /// the library: what a tool that names them reads.
  names,
}

/// One data asset a program ships.
final class ProgramDataAsset {
  ProgramDataAsset(this.package, this.name, this.file);

  /// The package the asset belongs to.
  final String package;

  /// Its name within the package, a relative path.
  final String name;

  /// The path of its file.
  final String file;

  /// `package:<package>/<name>`.
  String get id => 'package:$package/$name';
}

/// One code asset a program ships.
final class ProgramCodeAsset {
  ProgramCodeAsset(this.id, this.linkMode, this.file, this.fileName, this.uri);

  /// `package:<package>/<name>`.
  final String id;

  /// Upstream's link mode type: `dynamic_loading_bundle`,
  /// `dynamic_loading_system`, `dynamic_loading_process`,
  /// `dynamic_loading_executable` or `static`.
  final String linkMode;

  /// The path of its library, or `null` for an asset without one and in a
  /// file holding the code assets' names ([ProgramCodeView.names]).
  final String? file;

  /// The file name of its library, or `null` for an asset without one.
  final String? fileName;

  /// How the runtime finds it, for `dynamic_loading_system`, or `null`.
  final String? uri;
}

/// What a program ships, sorted by id: as much of it as the file holds.
final class ProgramAssets {
  ProgramAssets._(this.holdsData, this.codeView, this._data, this._code);

  /// Whether the file holds the data assets.
  final bool holdsData;

  /// What it holds of the code assets, or `null` for none.
  final ProgramCodeView? codeView;

  final List<ProgramDataAsset> _data;
  final List<ProgramCodeAsset> _code;

  /// Its data assets. Throws a [StateError] when the file does not hold
  /// them: its action was not handed them (`data = False`).
  List<ProgramDataAsset> get data => holdsData
      ? _data
      : throw StateError(
          'This program-assets file does not hold the data assets; pass '
          '`data = True` to `program_assets_action_args()`',
        );

  /// Its code assets. Throws a [StateError] when the file holds none: its
  /// action was not handed them (`code = None`).
  List<ProgramCodeAsset> get code => codeView != null
      ? _code
      : throw StateError(
          'This program-assets file does not hold the code assets; pass a '
          '`code` view to `program_assets_action_args()`',
        );

  /// Reads the file at [path], in the program-assets line format.
  ///
  /// Its paths are relative to the working directory (`--paths exec`, as an
  /// action is given them) or runfiles paths (`--paths runfiles`), which
  /// [runfiles] resolves, `Runfiles.create()` by default. Throws a
  /// [FormatException] for a file in another format or version, one with a
  /// record of something it does not hold, or one whose selection names an
  /// asset its link hook did not choose among.
  static ProgramAssets read(String path, {Runfiles? runfiles}) {
    final lines = File(path).readAsLinesSync();
    var at = 0;
    String next(String what) {
      if (at >= lines.length) {
        throw FormatException('$path ends where $what should be');
      }
      return lines[at++];
    }

    String tag(String expected) {
      final line = next('`$expected`');
      if (line != expected) {
        throw FormatException(
          '$path: expected `$expected` at line $at, found `$line`',
        );
      }
      return line;
    }

    tag('--format');
    final format = next('the format');
    if (format != programAssetsFormat) {
      throw FormatException(
        '$path is in the format `$format`; this reader reads '
        '`$programAssetsFormat`',
      );
    }
    tag('--paths');
    final String Function(String) resolve = switch (next('the paths')) {
      'exec' => (p) => p,
      'runfiles' => (runfiles ??= Runfiles.create()).rlocation,
      final other => throw FormatException('$path: unknown `--paths` `$other`'),
    };
    tag('--holds');
    var holdsData = false;
    ProgramCodeView? codeView;
    final holds = next('what it holds');
    final parts = holds.split(' ');
    if (holds.isEmpty ||
        parts.toSet().length != parts.length ||
        (parts.contains('code') && parts.contains('code-names'))) {
      throw FormatException('$path: `--holds` `$holds` is not a valid view');
    }
    for (final part in parts) {
      switch (part) {
        case 'data':
          holdsData = true;
        case 'code':
          codeView = ProgramCodeView.libraries;
        case 'code-names':
          codeView = ProgramCodeView.names;
        default:
          throw FormatException('$path: `--holds` names unknown `$part`');
      }
    }
    String? optional(String line) => line.isEmpty ? null : line;
    void holding(String record, bool held) {
      if (!held) {
        throw FormatException(
          '$path: a `$record` record in a file that holds `$holds`',
        );
      }
    }

    final data = <String, ProgramDataAsset>{};
    final code = <String, ProgramCodeAsset>{};
    void addData(ProgramDataAsset asset) {
      if (data.containsKey(asset.id)) {
        throw FormatException('$path names data asset `${asset.id}` twice');
      }
      data[asset.id] = asset;
    }

    void addCode(ProgramCodeAsset asset) {
      if (code.containsKey(asset.id)) {
        throw FormatException('$path names code asset `${asset.id}` twice');
      }
      code[asset.id] = asset;
    }

    ProgramCodeAsset codeAsset() {
      final id = next('an id');
      final linkMode = next('a link mode');
      final library = optional(next('a library'));
      final uri = optional(next('a uri'));
      final libraries = codeView == ProgramCodeView.libraries;
      if (!libraries && library != null && library.contains('/')) {
        throw FormatException(
          '$path: `$id` names its library by a path, `$library`, in a file '
          'that holds the code assets by name',
        );
      }
      return ProgramCodeAsset(
        id,
        linkMode,
        libraries && library != null ? resolve(library) : null,
        library?.substring(library.lastIndexOf('/') + 1),
        uri,
      );
    }

    while (at < lines.length) {
      switch (next('a record')) {
        case '--data-asset':
          holding('--data-asset', holdsData);
          final id = next('an id');
          final file = resolve(next('a file'));
          if (!id.startsWith('package:') || !id.contains('/')) {
            throw FormatException('$path: `$id` is not a data asset id');
          }
          final slash = id.indexOf('/');
          addData(
            ProgramDataAsset(
              id.substring('package:'.length, slash),
              id.substring(slash + 1),
              file,
            ),
          );
        case '--link-data':
          holding('--link-data', holdsData);
          final package = next('a package');
          final directory = resolve(next('a directory'));
          for (final (name, file) in _members(directory)) {
            addData(ProgramDataAsset(package, name, file));
          }
        case '--code-asset':
          holding('--code-asset', codeView != null);
          addCode(codeAsset());
        case '--link-code':
          holding('--link-code', codeView != null);
          final package = next('a package');
          final selection = resolve(next('a selection'));
          final candidates = <String, ProgramCodeAsset>{};
          while (at < lines.length && lines[at] == '--candidate') {
            at++;
            final candidate = codeAsset();
            candidates[candidate.id] = candidate;
          }
          if (candidates.isEmpty) {
            throw FormatException(
              '$path: the link hook of `$package` has a selection and no '
              'code assets it chose among',
            );
          }
          for (final id in File(selection).readAsLinesSync()) {
            if (id.isEmpty) continue;
            final candidate = candidates[id];
            if (candidate == null) {
              throw FormatException(
                '$path: the link hook of `$package` kept `$id`, which is not '
                'one of the code assets it chose among',
              );
            }
            addCode(candidate);
          }
        case final other:
          throw FormatException('$path: unknown record `$other` at line $at');
      }
    }
    return ProgramAssets._(
      holdsData,
      codeView,
      [for (final id in data.keys.toList()..sort()) data[id]!],
      [for (final id in code.keys.toList()..sort()) code[id]!],
    );
  }

  /// One line per asset the file holds, data assets first, each sorted by
  /// id: tab-separated `data`, the id and the file; or `code`, the id, the
  /// link mode and, when it has one, its library (its path, or its file name
  /// in a file holding the code assets by name) or its uri.
  String describe() => [
    if (holdsData)
      for (final asset in _data) 'data\t${asset.id}\t${asset.file}\n',
    if (codeView != null)
      for (final asset in _code)
        '${['code', asset.id, asset.linkMode, ?(asset.file ?? asset.fileName ?? asset.uri)].join('\t')}\n',
  ].join();
}

/// Each file under [directory], following links as a sandbox stages them, as
/// its name (its path in the directory, `/`-separated) and its path.
List<(String, String)> _members(String directory) {
  final root = Directory(directory);
  final prefix = root.path.endsWith(Platform.pathSeparator)
      ? root.path
      : '${root.path}${Platform.pathSeparator}';
  return [
    for (final entity in root.listSync(recursive: true, followLinks: true))
      if (entity is File)
        (
          entity.path
              .substring(prefix.length)
              .replaceAll(Platform.pathSeparator, '/'),
          entity.path,
        ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
}
