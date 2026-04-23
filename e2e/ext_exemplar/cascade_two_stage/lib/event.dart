import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';
part 'event.g.dart';

// freezed auto-detects `fromJson` via `Library.hasJson`, which walks imports
// and checks `element.library.firstFragment.source.fullName.startsWith(
// '/json_annotation/')`. Our package roots live at paths like
// `/.../rules_dart++pub+dart_pub__json_annotation/...`, so the startsWith
// check misses — freezed can't be patched per project policy. Declare the
// JSON methods explicitly so the generator emits them regardless.
@Freezed(fromJson: true, toJson: true)
abstract class Event with _$Event {
  const factory Event({
    required String type,
    required int sequence,
  }) = _Event;

  factory Event.fromJson(Map<String, Object?> json) => _$EventFromJson(json);
}
