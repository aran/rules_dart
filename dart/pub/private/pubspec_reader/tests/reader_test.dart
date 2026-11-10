/// Checks what a repository reads from each pubspec under testdata/ (through
/// `run_pubspec_reader`, collected in `@pubspec_reader_cases//:results.json`)
/// against `package:yaml` itself: the same document, the same dependencies
/// and SDK constraint, and package:yaml's own message for a file it refuses.
/// Files pub's field checks refuse are listed below with pub's message.
///
/// Arguments: the runfiles paths of results.json and of every testdata file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:runfiles/runfiles.dart';
import 'package:term_glyph/term_glyph.dart' as glyph;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The files pub refuses past package:yaml, with pub's message for each.
const refusedByPub = {
  'c17_sdk_numeric.yaml': 'A version constraint must be a string.',
  'e01_environment_not_map.yaml': '"environment" field must be a map.',
  'e02_dependencies_list.yaml': '"dependencies" field must be a map.',
  'e03_depends_on_itself.yaml':
      'A package may not list itself as a dependency.',
  'e04_dependency_name_invalid.yaml': 'Not a valid package name.',
  'e05_dependency_spec_number.yaml':
      'A dependency specification must be a string or a mapping.',
  'e06_two_sources.yaml': 'A dependency may only have one source.',
  'e07_name_missing.yaml': 'Missing the required "name" field.',
  'e08_name_mismatch.yaml': '"name" field doesn\'t match expected name "x".',
  'e09_dart_sdk_key.yaml': 'Use "sdk" to for Dart SDK constraints.',
  'e10_flutter_numeric.yaml': 'A version constraint must be a string.',
  'e11_not_a_mapping.yaml': 'The pubspec must be a YAML mapping.',
  'e12_empty.yaml': 'Missing the required "name" field.',
  'e13_version_in_map_numeric.yaml': 'A version constraint must be a string.',
  'e14_name_not_string.yaml': '"name" field must be a String.',
  'e15_dependency_name_number.yaml': 'A dependency name must be a string.',
  'e16_reserved_name.yaml': '"name" field may not be a Dart reserved word.',
  // JSON, and so Starlark, cannot hold these documents.
  'o03_colliding_keys.yaml': 'Two mapping keys read as "1".',
  'o04_collection_key.yaml':
      'A mapping key is a collection, which rules_dart cannot read.',
};

/// The language version pub gives each file, by pub's rule: the lower bound of
/// `environment.sdk`, "2.7" where there is none. Every other file's is checked
/// for its shape only.
const languageVersions = {
  'l01_two_lower_bounds.yaml': '3.0',
  'l02_leading_zeros.yaml': '3.4',
  'l03_empty_range.yaml': '2.7',
  'l04_empty_exclusive.yaml': '2.7',
  'l05_any.yaml': '2.7',
  'l06_caret.yaml': '3.5',
  'l07_caret_prerelease.yaml': '3.0',
  'l08_range.yaml': '2.12',
  'l09_exclusive_lower.yaml': '2.12',
  'l10_space_after_operator.yaml': '2.12',
  'l11_upper_only.yaml': '2.7',
  'l12_bare_version.yaml': '2.12',
  'l13_upper_before_lower.yaml': '3.1',
  'l14_big_components.yaml': '12.34',
  'l17_no_environment.yaml': '2.7',
};

/// `environment.sdk` values pub_semver does not parse, with its message. It has
/// no `||`: pub refuses a union written that way.
const unparsableSdk = {
  'l15_union_syntax.yaml':
      'Could not parse the SDK constraint "^2.0.0 || ^3.0.0"',
  'l16_garbage.yaml': 'Could not parse the SDK constraint "garbage"',
};

/// The document as JSON holds it, converted independently of the reader.
Object? toJson(Object? value) => switch (value) {
  Map() => {for (final e in value.entries) '${e.key}': toJson(e.value)},
  List() => [for (final v in value) toJson(v)],
  double() when !value.isFinite => '$value',
  _ => value,
};

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final results = jsonDecode(
    File(runfiles.rlocation(args.first)).readAsStringSync(),
  ) as Map<String, Object?>;
  final files = {
    for (final a in args.skip(1)) a.substring(a.lastIndexOf('/') + 1): a,
  };
  glyph.ascii = true;

  test('every file under testdata/ was read', () {
    expect(results.keys.toSet(), files.keys.toSet());
  });

  for (final MapEntry(key: name, value: path) in files.entries) {
    test(name, () {
      final result = results[name] as Map<String, Object?>;
      final content = File(runfiles.rlocation(path)).readAsStringSync();
      final YamlNode document;
      try {
        document = loadYamlNode(content, sourceUrl: Uri.file(name));
      } on YamlException catch (e) {
        expect(result, {'error': e.toString()});
        return;
      }
      final pubMessage = refusedByPub[name];
      if (pubMessage != null) {
        expect(result.keys, ['error']);
        expect(result['error'], contains('of $name: $pubMessage'));
        return;
      }
      final unparsable = unparsableSdk[name];
      if (unparsable != null) {
        expect(result.keys, ['error']);
        expect(result['error'], contains('of $name: '));
        expect(result['error'], contains(unparsable));
        return;
      }
      final fields = toJson(document.value) as Map<String, Object?>;
      final dependencies = fields['dependencies'];
      final environment = fields['environment'];
      final expected = {
        'name': fields['name'],
        'dependencies': dependencies is Map
            ? dependencies.keys.toList()
            : <Object?>[],
        'sdk_constraint': environment is Map ? environment['sdk'] ?? '' : '',
        'fields': fields,
      };
      expect(result.keys, ['ok']);
      final ok = Map<String, Object?>.of(result['ok'] as Map<String, Object?>);
      final languageVersion = ok.remove('language_version');
      final expectedLanguageVersion = languageVersions[name];
      if (expectedLanguageVersion != null) {
        expect(languageVersion, expectedLanguageVersion);
      } else {
        expect(languageVersion, matches(r'^\d+\.\d+$'));
      }
      expect(
        const DeepCollectionEquality().equals(ok, expected),
        isTrue,
        reason: 'read:\n$ok\npackage:yaml:\n$expected',
      );
    });
  }
}
