import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';

// Simple freezed value class: structural equality + toString + copyWith
// generated without any union/sealed scaffolding.

/// A freezed value class.
@freezed
abstract class Event with _$Event {
  /// Creates an event of [type] at [sequence].
  const factory Event({
    required String type,
    required int sequence,
  }) = _Event;
}
