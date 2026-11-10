import 'package:json_annotation/json_annotation.dart';

import 'event.dart';
import 'greeting.dart';

part 'member.g.dart';

/// Imports `greeting.dart`, which imports it back, and `event.dart`, whose
/// `toJson` freezed writes: json_serializable sees both through the macro's
/// `asset_deps`, freezed's output among them.
@JsonSerializable(explicitToJson: true)
class Member {
  /// Creates a member who last did [lastEvent].
  Member({required this.name, required this.lastEvent});

  /// Deserializes a [Member] from [json].
  factory Member.fromJson(Map<String, dynamic> json) => _$MemberFromJson(json);

  /// The member's name.
  final String name;

  /// What the member last did.
  final Event lastEvent;

  /// How the plain library greets this member.
  String get greeting => greet(this);

  /// Serializes this member to JSON.
  Map<String, dynamic> toJson() => _$MemberToJson(this);
}
