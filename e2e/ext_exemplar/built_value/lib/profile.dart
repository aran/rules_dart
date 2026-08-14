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
abstract class Profile implements Built<Profile, ProfileBuilder> {
  factory Profile([void Function(ProfileBuilder) updates]) = _$Profile;
  Profile._();

  static Serializer<Profile> get serializer => _$profileSerializer;

  // Getter order drives the generated serializer's field order; keep it.
  String get name;
  int get age;
  String? get bio;
  BuiltList<String> get tags;
}
