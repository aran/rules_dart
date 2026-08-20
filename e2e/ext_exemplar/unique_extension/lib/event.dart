import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';

/// A minimal freezed model.
@freezed
abstract class Event with _$Event {
  /// Creates an event of [type] at [sequence].
  const factory Event({
    required String type,
    required int sequence,
  }) = _Event;
}
