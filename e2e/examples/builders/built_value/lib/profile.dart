import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

part 'profile.g.dart';

// Profile exercises more of built_value's feature surface than User:
//   - nullable `bio` (serializer must handle null roundtrip)
//   - `BuiltList<String> tags` (collection serializer)
//   - a static `Serializer<Profile>` getter (wired via @SerializersFor)
//
// Paired with serializers.dart / standardSerializers, this proves the
// full JSON-over-built_value path works end-to-end.

/// A built_value model exercising nullable and collection fields.
abstract class Profile implements Built<Profile, ProfileBuilder> {
  /// Creates a [Profile] from builder [updates].
  factory Profile([void Function(ProfileBuilder) updates]) = _$Profile;
  Profile._();

  /// The generated serializer for [Profile].
  static Serializer<Profile> get serializer => _$profileSerializer;

  // Getter order drives the generated serializer's field order; keep it.

  /// The profile's display name.
  String get name;

  /// The profile's age in years.
  int get age;

  /// An optional free-form bio.
  String? get bio;

  /// Tags attached to the profile.
  BuiltList<String> get tags;
}
