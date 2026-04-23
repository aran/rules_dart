import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';

import 'serializers.dart';

part 'profile.g.dart';

// Profile exercises more of built_value's feature surface than User:
//   - nullable `bio` (serializer must handle null roundtrip)
//   - `BuiltList<String> tags` (collection serializer)
//   - a static `Serializer<Profile>` getter (wired via @SerializersFor)
//
// Paired with serializers.dart / standardSerializers, this proves the
// full JSON-over-built_value path works end-to-end.
abstract class Profile implements Built<Profile, ProfileBuilder> {
  String get name;
  int get age;
  String? get bio;
  BuiltList<String> get tags;

  Profile._();
  factory Profile([void Function(ProfileBuilder) updates]) = _$Profile;

  static Serializer<Profile> get serializer => _$profileSerializer;
}
