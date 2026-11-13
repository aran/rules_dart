import 'package:json_annotation/json_annotation.dart';

part 'model.g.dart';

/// Someone to greet.
@JsonSerializable()
class Visitor {
  /// A visitor called [name], here [visits] times.
  Visitor(this.name, this.visits);

  /// The visitor in [json].
  factory Visitor.fromJson(Map<String, dynamic> json) =>
      _$VisitorFromJson(json);

  /// The visitor's name.
  final String name;

  /// How many times they have visited.
  final int visits;

  /// This visitor as JSON.
  Map<String, dynamic> toJson() => _$VisitorToJson(this);
}
