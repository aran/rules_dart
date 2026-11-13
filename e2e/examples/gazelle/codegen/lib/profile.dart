import 'package:copy_with_extension/copy_with_extension.dart';
import 'package:json_annotation/json_annotation.dart';

part 'profile.g.dart';

/// Two shared-part builders, whose shards the combining stage merges into
/// one `profile.g.dart`.
@JsonSerializable()
@CopyWith()
class Profile {
  /// Creates a profile.
  Profile({required this.handle, required this.bio});

  /// Deserializes a [Profile] from [json].
  factory Profile.fromJson(Map<String, dynamic> json) =>
      _$ProfileFromJson(json);

  /// The profile's handle.
  final String handle;

  /// The profile's biography.
  final String bio;

  /// Serializes this profile to JSON.
  Map<String, dynamic> toJson() => _$ProfileToJson(this);
}
