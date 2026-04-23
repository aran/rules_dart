import 'package:test/test.dart';

import '../bin/main.dart' show combine;

void main() {
  group('combining_shim.combine', () {
    test('emits the standard header + `part of` with the source basename', () {
      final out = combine(sourceBasename: 'user.dart', partContents: []);
      expect(out, contains('// GENERATED CODE - DO NOT MODIFY BY HAND'));
      // Header must match `source_gen|combining_builder` byte-for-byte so
      // a build_runner-produced `.g.dart` and a rules_dart-produced one
      // are diffable during a migration.
      expect(out, isNot(contains('rules_dart_ext')));
      expect(out, contains("part of 'user.dart';"));
    });

    test('top-of-file layout matches build_runner combining_builder', () {
      final shard = '''
part of 'user.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

User _\$UserFromJson(Map<String, dynamic> json) => User();
''';
      final out = combine(sourceBasename: 'user.dart', partContents: [shard]);
      // Same preamble build_runner emits: GENERATED header, blank, `part of`,
      // blank, then per-shard content (which carries its own `// Generator:`
      // marker from the SharedPartBuilder).
      expect(
        out.split('\n').take(5).toList(),
        equals([
          '// GENERATED CODE - DO NOT MODIFY BY HAND',
          '',
          "part of 'user.dart';",
          '',
          '// **************************************************************************',
        ]),
      );
    });

    test('no trailing blank after the final shard (build_runner parity)', () {
      final out = combine(
        sourceBasename: 'x.dart',
        partContents: ['class A {}\n'],
      );
      // Single trailing newline — matches `source_gen|combining_builder`.
      expect(out.endsWith('class A {}\n'), isTrue);
      expect(out.endsWith('\n\n'), isFalse);
    });

    test('concatenates multiple shards in the order provided', () {
      final out = combine(
        sourceBasename: 'user.dart',
        partContents: [
          '/// shard A\nclass A {}\n',
          '/// shard B\nclass B {}\n',
        ],
      );
      expect(out.indexOf('class A'), lessThan(out.indexOf('class B')));
    });

    test('strips leading `part of` directives from each shard', () {
      final out = combine(
        sourceBasename: 'user.dart',
        partContents: [
          "part of 'user.dart';\n\nclass A {}\n",
        ],
      );
      // Exactly one `part of` directive — the combining shim's own header —
      // not the one the SharedPartBuilder shard emitted.
      expect('part of'.allMatches(out).length, 1);
      expect(out, contains("part of 'user.dart';"));
      expect(out, contains('class A'));
    });

    test('skips empty / whitespace-only shards', () {
      final out = combine(
        sourceBasename: 'user.dart',
        partContents: ['', '   \n  \n', "part of 'user.dart';\n"],
      );
      // None of the shards contribute content; the output is just header +
      // `part of` header, no trailing class/function text.
      expect(out, contains("part of 'user.dart';"));
      expect(out, isNot(contains('class')));
    });

    test('preserves ordering as given (the rule layer pre-sorts)', () {
      final out = combine(
        sourceBasename: 'x.dart',
        partContents: ['class Z {}\n', 'class A {}\n'],
      );
      // Caller-controlled order — combine doesn't re-sort.
      expect(out.indexOf('class Z'), lessThan(out.indexOf('class A')));
    });
  });
}
