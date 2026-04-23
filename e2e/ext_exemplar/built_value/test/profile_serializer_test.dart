import 'package:built_collection/built_collection.dart';
import 'package:built_value_sample/profile.dart';
import 'package:built_value_sample/serializers.dart';
import 'package:test/test.dart';

void main() {
  group('built_value Serializer<Profile> + StandardJsonPlugin', () {
    test('serializes + deserializes an all-fields-populated profile', () {
      final profile = Profile((b) => b
        ..name = 'Aria'
        ..age = 30
        ..bio = 'likes dart'
        ..tags.addAll(['rust', 'dart']));

      final json =
          standardSerializers.serializeWith(Profile.serializer, profile);
      expect(json, isA<Map<String, Object?>>());
      final map = json as Map<String, Object?>;
      expect(map['name'], 'Aria');
      expect(map['age'], 30);
      expect(map['bio'], 'likes dart');
      expect(map['tags'], ['rust', 'dart']);

      final roundTripped =
          standardSerializers.deserializeWith(Profile.serializer, json);
      expect(roundTripped, equals(profile));
    });

    test('round-trips a profile with nullable bio unset', () {
      final profile = Profile((b) => b
        ..name = 'Kai'
        ..age = 22
        ..tags.replace(<String>[]));
      // bio intentionally not assigned — should remain null through the
      // full serialize/deserialize path.

      final json =
          standardSerializers.serializeWith(Profile.serializer, profile);
      final map = json as Map<String, Object?>;
      expect(map.containsKey('bio'), isFalse,
          reason: 'StandardJsonPlugin should omit unset nullable fields');

      final roundTripped = standardSerializers
          .deserializeWith(Profile.serializer, json) as Profile;
      expect(roundTripped, equals(profile));
      expect(roundTripped.bio, isNull);
    });

    test('BuiltList<String> tags roundtrip preserves element order', () {
      final profile = Profile((b) => b
        ..name = 'Nox'
        ..age = 17
        ..tags.replace(<String>['c', 'b', 'a']));

      final json = standardSerializers.serializeWith(
          Profile.serializer, profile) as Map;
      expect(json['tags'], orderedEquals(<String>['c', 'b', 'a']));

      final roundTripped = standardSerializers
          .deserializeWith(Profile.serializer, json) as Profile;
      expect(
          roundTripped.tags, orderedEquals(BuiltList<String>(['c', 'b', 'a'])));
    });
  });
}
