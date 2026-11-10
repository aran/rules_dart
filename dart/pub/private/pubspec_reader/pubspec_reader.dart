// Reads a pubspec.yaml with package:yaml, the loader pub uses, applies pub's
// checks to the fields rules_dart reads, and prints one line of JSON:
//
//   {"ok": {"name": ..., "dependencies": [...], "sdk": ... or null,
//           "language_version": "<major>.<minor>",
//           "fields": <the whole document>}}
//   {"error": "<the message pub would give, with its line and column>"}
//
// Usage: pubspec_reader <pubspec.yaml> [<expected package name>]
//
// The file is named in messages as it is given, so a caller passes the path it
// wants a reader to see. Any other exit than 0 with one of those lines is a
// crash of the reader itself.
import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:source_span/source_span.dart';
import 'package:term_glyph/term_glyph.dart' as glyph;
import 'package:yaml/yaml.dart';

/// pub's `identifierRegExp`, as `packageNameRegExp` composes it.
const _identifier = r'[a-zA-Z_]\w*';
final _packageName = RegExp('^$_identifier(\\.$_identifier)*\$');

/// The words pub refuses as a package name: its `reservedWords`.
const _reservedWords = {
  'abstract',
  'as',
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'external',
  'false',
  'final',
  'finally',
  'for',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'inline',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

Never _error(String message, SourceSpan span) =>
    throw SourceSpanFormatException(message, span);

/// The document as JSON values. A key that is not a scalar, or two keys that
/// read the same as strings (`1` and `"1"`), cannot be a JSON object key.
Object? _plain(YamlNode node) {
  if (node is YamlMap) {
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in node.nodes.entries) {
      final keyNode = key as YamlNode;
      if (keyNode is! YamlScalar) {
        _error(
          'A mapping key is a collection, which rules_dart cannot read.',
          keyNode.span,
        );
      }
      final name = '${keyNode.value}';
      if (out.containsKey(name)) {
        _error('Two mapping keys read as "$name".', keyNode.span);
      }
      out[name] = _plain(value);
    }
    return out;
  }
  if (node is YamlList) return [for (final n in node.nodes) _plain(n)];
  final value = node.value;
  if (value is double && !value.isFinite) return '$value';
  return value;
}

/// pub's `expectPackageNameField`, and its check against the name a package
/// was fetched as.
String _name(YamlMap fields, String? expected) {
  final value = fields['name'];
  final span = fields.nodes['name']?.span ?? fields.span;
  if (value == null) _error('Missing the required "name" field.', span);
  if (value is! String) _error('"name" field must be a String.', span);
  if (!_packageName.hasMatch(value)) {
    _error('"name" field must be a valid Dart identifier.', span);
  }
  if (_reservedWords.contains(value.toLowerCase())) {
    _error('"name" field may not be a Dart reserved word.', span);
  }
  if (expected != null && value != expected) {
    _error('"name" field doesn\'t match expected name "$expected".', span);
  }
  return value;
}

/// pub's `_parseVersionConstraint`, as far as the value's type.
void _versionConstraint(YamlNode? node) {
  if (node == null || node.value == null) return;
  if (node.value is! String) {
    _error('A version constraint must be a string.', node.span);
  }
}

/// pub's `_parseDependencies`, short of each source's description.
List<String> _dependencies(YamlMap fields, String field, String name) {
  final node = fields.nodes[field];
  if (node == null || node.value == null) return const [];
  if (node is! YamlMap) _error('"$field" field must be a map.', node.span);
  final names = <String>[];
  for (final MapEntry(:key, value: spec) in node.nodes.entries) {
    final nameNode = key as YamlNode;
    final dependency = nameNode.value;
    if (dependency is! String) {
      _error('A dependency name must be a string.', nameNode.span);
    }
    if (!_packageName.hasMatch(dependency)) {
      _error('Not a valid package name.', nameNode.span);
    }
    if (dependency == name) {
      _error('A package may not list itself as a dependency.', nameNode.span);
    }
    if (spec.value == null) {
      // Any version, from the default source.
    } else if (spec.value is String) {
      _versionConstraint(spec);
    } else if (spec is YamlMap) {
      _versionConstraint(spec.nodes['version']);
      final sources = spec.nodes.keys
          .cast<YamlNode>()
          .where((k) => k.value != 'version')
          .toList();
      if (sources.length > 1) {
        _error('A dependency may only have one source.', spec.span);
      }
      if (sources.length == 1 && sources.single.value is! String) {
        _error('A source name must be a string.', sources.single.span);
      }
    } else {
      _error(
        'A dependency specification must be a string or a mapping.',
        spec.span,
      );
    }
    names.add(dependency);
  }
  return names;
}

/// pub's `defaultLanguageVersion`, for a package whose SDK constraint has no
/// lower bound.
const _defaultLanguageVersion = '2.7';

/// pub's `LanguageVersion.fromSdkConstraint`: the lower bound of the SDK
/// constraint, as `<major>.<minor>`.
String _languageVersion(VersionConstraint? constraint) {
  Version? min;
  if (constraint == null || constraint.isEmpty) {
    min = null;
  } else if (constraint is Version) {
    min = constraint;
  } else if (constraint is VersionRange) {
    min = constraint.min;
  } else if (constraint is VersionUnion) {
    min = constraint.ranges.first.min;
  } else {
    throw ArgumentError('Unknown VersionConstraint type $constraint.');
  }
  return min == null ? _defaultLanguageVersion : '${min.major}.${min.minor}';
}

/// pub's `_parseEnvironment`: the Dart SDK constraint, or null for none.
String? _sdk(YamlMap fields) {
  final node = fields.nodes['environment'];
  if (node == null || node.value == null) return null;
  if (node is! YamlMap) {
    _error('"environment" field must be a map.', node.span);
  }
  _versionConstraint(node.nodes['sdk']);
  for (final MapEntry(:key, :value) in node.nodes.entries) {
    final nameNode = key as YamlNode;
    final sdk = nameNode.value;
    if (sdk is! String) _error('SDK names must be strings.', nameNode.span);
    if (sdk == 'dart') {
      _error('Use "sdk" to for Dart SDK constraints.', nameNode.span);
    }
    if (sdk != 'sdk') _versionConstraint(value);
  }
  return node['sdk'] as String?;
}

/// The language version pub gives a package with this `environment.sdk`.
String _sdkLanguageVersion(YamlMap fields, String? sdk) {
  if (sdk == null) return _defaultLanguageVersion;
  try {
    return _languageVersion(VersionConstraint.parse(sdk));
  } on FormatException catch (e) {
    final node = (fields.nodes['environment'] as YamlMap).nodes['sdk']!;
    _error(
      'Could not parse the SDK constraint "$sdk": ${e.message}',
      node.span,
    );
  }
}

Map<String, Object?> read(String path, String? expectedName) {
  final YamlNode document;
  try {
    document = loadYamlNode(
      File(path).readAsStringSync(),
      sourceUrl: Uri.file(path),
    );
  } on FileSystemException catch (e) {
    return {'error': 'Cannot read $path: ${e.osError?.message ?? e.message}'};
  }
  // pub's `_ensureMap`: an empty document is an empty mapping.
  final YamlMap fields;
  if (document is YamlScalar && document.value == null) {
    fields = YamlMap(sourceUrl: document.span.sourceUrl);
  } else if (document is YamlMap) {
    fields = document;
  } else {
    _error('The pubspec must be a YAML mapping.', document.span);
  }
  final name = _name(fields, expectedName);
  final dependencies = _dependencies(fields, 'dependencies', name);
  final sdk = _sdk(fields);
  return {
    'ok': {
      'name': name,
      'dependencies': dependencies,
      'sdk': sdk,
      'language_version': _sdkLanguageVersion(fields, sdk),
      'fields': _plain(fields),
    },
  };
}

void main(List<String> args) {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('usage: pubspec_reader <pubspec.yaml> [<expected name>]');
    exit(2);
  }
  // Messages are read in Bazel's output, not a terminal that draws boxes.
  glyph.ascii = true;
  Map<String, Object?> result;
  try {
    result = read(args[0], args.length > 1 ? args[1] : null);
  } on SourceSpanException catch (e) {
    result = {'error': e.toString()};
  }
  stdout.writeln(jsonEncode(result));
}
