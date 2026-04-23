import 'package:copy_with_extension/copy_with_extension.dart';

part 'user.g.dart';

// Exercises the full public surface of copy_with_extension_gen:
//
//   - basic `@CopyWith()` — a per-field `.copyWith.<field>(value)` shortcut
//     and a bulk `.copyWith(...)` method
//   - `copyWithNull: true` — generator emits a `copyWithNull(...)` method
//     so nullable fields can be explicitly reset to null (without this,
//     passing `null` to `.copyWith(bio: null)` is ambiguous with
//     "unset parameter" and the generator treats omitted == unset)
//   - `@CopyWithField(immutable: true)` — per-field opt-out from both
//     `copyWith` and `copyWithNull`; the field keeps its original value
//     and cannot be overridden via the generated interfaces
@CopyWith(copyWithNull: true)
class User {
  User({
    required this.id,
    required this.name,
    required this.active,
    required this.createdAt,
    this.bio,
  });

  final String id;
  final String name;
  final bool active;
  final String? bio;

  // `createdAt` is treated as immutable — the generator must NOT produce
  // a `.copyWith(createdAt: ...)` parameter or a `.copyWith.createdAt(...)`
  // shortcut. It is always carried over verbatim.
  @CopyWithField(immutable: true)
  final int createdAt;
}
