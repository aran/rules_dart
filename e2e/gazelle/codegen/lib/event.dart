import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';
part 'event.g.dart';

/// Two stages: json_serializable reads the class freezed generates.
// freezed finds json_annotation by a path test that pub's layout passes and
// Bazel's does not, so the JSON methods are asked for explicitly.
@Freezed(fromJson: true, toJson: true)
abstract class Event with _$Event {
  /// Creates an event of [type] at [sequence].
  // ignore: unnecessary_type_name_in_constructor
  const factory Event({required String type, required int sequence}) = _Event;

  /// Deserializes an [Event] from [json].
  // ignore: unnecessary_type_name_in_constructor
  factory Event.fromJson(Map<String, Object?> json) => _$EventFromJson(json);
}
