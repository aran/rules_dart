import 'package:copy_with/user.dart';
import 'package:test/test.dart';

void main() {
  final sample = User(
    id: 'alpha',
    name: 'Alice',
    active: true,
    createdAt: 100,
    bio: 'likes dart',
  );

  group('@CopyWith() basic features', () {
    test('.copyWith(...) bulk updates leave unspecified fields alone', () {
      final renamed = sample.copyWith(name: 'Alicia');
      expect(renamed.id, 'alpha');
      expect(renamed.name, 'Alicia');
      expect(renamed.active, isTrue);
      expect(renamed.bio, 'likes dart');
      expect(renamed.createdAt, 100);
    });

    test('.copyWith.<field>(value) shortcut is generated per mutable field',
        () {
      final deactivated = sample.copyWith.active(false);
      expect(deactivated.active, isFalse);
      expect(deactivated.name, 'Alice');
      expect(deactivated.id, 'alpha');
    });
  });

  group('@CopyWith(copyWithNull: true)', () {
    test('copyWithNull nullifies a nullable field that was previously set',
        () {
      final cleared = sample.copyWithNull(bio: true);
      expect(cleared.bio, isNull);
      // Non-nulled fields unchanged.
      expect(cleared.id, 'alpha');
      expect(cleared.name, 'Alice');
      expect(cleared.active, isTrue);
      expect(cleared.createdAt, 100);
    });

    test('copyWithNull(bio: false) is a no-op for that field', () {
      final untouched = sample.copyWithNull(bio: false);
      expect(untouched.bio, 'likes dart');
    });
  });

  group('@CopyWithField(immutable: true)', () {
    test('createdAt is carried through unchanged after any copyWith', () {
      // createdAt must not shift regardless of what we copyWith. The
      // generator refuses to emit a `createdAt:` parameter on any of the
      // generated methods — we assert by observing the value rather than
      // by negative static-typing (runtime is the reliable guardrail).
      expect(sample.copyWith(name: 'X').createdAt, 100);
      expect(sample.copyWith.name('X').createdAt, 100);
      expect(sample.copyWithNull(bio: true).createdAt, 100);
    });
  });
}
