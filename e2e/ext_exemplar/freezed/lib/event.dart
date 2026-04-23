import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';

// Simple freezed value class: structural equality + toString + copyWith
// generated without any union/sealed scaffolding.
@freezed
abstract class Event with _$Event {
  const factory Event({
    required String type,
    required int sequence,
  }) = _Event;
}
