import 'package:json_annotation/json_annotation.dart';

part 'address.g.dart';

/// An annotated source in a directory under lib/: Gazelle writes its
/// `json_serializable_codegen` in the package's BUILD file, named for its
/// path under lib/.
@JsonSerializable()
class Address {
  /// Creates an address.
  Address({required this.city});

  /// Deserializes an [Address] from [json].
  factory Address.fromJson(Map<String, dynamic> json) =>
      _$AddressFromJson(json);

  /// The city.
  final String city;

  /// Serializes this address to JSON.
  Map<String, dynamic> toJson() => _$AddressToJson(this);
}
