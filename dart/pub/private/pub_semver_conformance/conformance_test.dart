/// Checks `version.bzl` against `package:pub_semver`: for each case `cases.bzl`
/// lists, what Starlark answered is what pub_semver answers here. The cases
/// carry no expected values, so the two cannot disagree unnoticed.
///
/// Argument: the runfiles path of the results `version_results` wrote.
library;

import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Whatever `parse` throws is a refusal: a too-large `^` bound is an
/// `ArgumentError`, not a `FormatException`.
T? _attempt<T>(T Function() parse) {
  try {
    return parse();
  } on Object {
    return null;
  }
}

/// A string as the failure output can show it.
String _shown(String text) => jsonEncode(text);

void main(List<String> args) {
  final results = jsonDecode(
    File(Runfiles.create().rlocation(args.single)).readAsStringSync(),
  ) as Map<String, Object?>;
  final texts = (results['versions'] as List).cast<String>();
  final versions = [for (final text in texts) Version.parse(text)];

  test('versions order as Version.compareTo orders them', () {
    final ranks = (results['ranks'] as List).cast<int>();
    final wrong = <String>[];
    for (var a = 0; a < versions.length; a++) {
      for (var b = 0; b < versions.length; b++) {
        final expected = versions[a].compareTo(versions[b]).sign;
        if (ranks[a].compareTo(ranks[b]).sign != expected) {
          wrong.add('${texts[a]} against ${texts[b]}: pub_semver $expected');
        }
      }
    }
    expect(wrong, isEmpty);
  });

  test('is_semver accepts what Version.parse accepts', () {
    final wrong = <String>[];
    (results['is_version'] as Map).cast<String, bool>().forEach((text, valid) {
      if ((_attempt(() => Version.parse(text)) != null) != valid) {
        wrong.add('${_shown(text)}: Starlark says $valid');
      }
    });
    expect(wrong, isEmpty);
  });

  test('constraints parse and allow as VersionConstraint does', () {
    final cases = (results['constraints'] as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThan(3000));
    var refused = 0;
    final wrong = <String>[];
    for (final entry in cases) {
      final text = entry['text'] as String;
      final constraint = _attempt(() => VersionConstraint.parse(text));
      if ((constraint != null) != entry['valid']) {
        wrong.add('${_shown(text)}: Starlark says valid=${entry['valid']}');
        continue;
      }
      if (constraint == null) {
        refused++;
        continue;
      }
      final allows = entry['allows'] as String;
      for (var i = 0; i < versions.length; i++) {
        if (constraint.allows(versions[i]) != (allows[i] == '1')) {
          wrong.add(
            '${_shown(text)} and ${texts[i]}: Starlark says ${allows[i]}',
          );
        }
      }
    }
    expect(wrong, isEmpty);
    // The table exercises both sides of the grammar.
    expect(refused, greaterThan(100));
    expect(cases.length - refused, greaterThan(1000));
  });
}
