import 'package:freezed_annotation/freezed_annotation.dart';

part 'event.freezed.dart';

/// A minimal freezed model.
@freezed
abstract class Event with _$Event {
  /// Creates an event of [type] at [sequence].
  // freezed 4.0.2 does not recognise a factory written without the class name.
  // ignore: unnecessary_type_name_in_constructor
  const factory Event({required String type, required int sequence}) = _Event;
}
