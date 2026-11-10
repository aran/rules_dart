import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';
part 'event.g.dart';

@freezed
abstract class Event with _$Event {
  const factory Event({required String id}) = _Event;

  factory Event.fromJson(Map<String, Object?> json) => _$EventFromJson(json);
}
