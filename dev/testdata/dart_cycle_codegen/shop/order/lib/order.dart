import 'package:customer/customer.dart';
import 'package:json_annotation/json_annotation.dart';

part 'order.g.dart';

/// An order, placed by a [Customer] of the other package.
@JsonSerializable()
class Order {
  /// Creates an order.
  new({required this.id, required this.customer});

  /// Deserializes an [Order] from [json].
  factory fromJson(Map<String, dynamic> json) => _$OrderFromJson(json);

  /// The order's id.
  final String id;

  /// Who placed it.
  final Customer customer;

  /// Serializes this order to JSON.
  Map<String, dynamic> toJson() => _$OrderToJson(this);
}
