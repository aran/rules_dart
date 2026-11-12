import 'package:json_annotation/json_annotation.dart';
import 'package:order/order.dart';

part 'customer.g.dart';

/// A customer, who places the [Order]s of the other package.
@JsonSerializable()
class Customer {
  /// Creates a customer.
  new({required this.name, this.orderIds = const []});

  /// Deserializes a [Customer] from [json].
  factory fromJson(Map<String, dynamic> json) => _$CustomerFromJson(json);

  /// The customer's name.
  final String name;

  /// The ids of the orders it placed.
  final List<String> orderIds;

  /// Serializes this customer to JSON.
  Map<String, dynamic> toJson() => _$CustomerToJson(this);

  /// Whether [order] is one this customer placed.
  bool placed(Order order) => orderIds.contains(order.id);
}
