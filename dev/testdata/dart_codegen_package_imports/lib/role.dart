import 'package:freezed_annotation/freezed_annotation.dart';

part 'role.freezed.dart';

@freezed
abstract class Role with _$Role {
  const factory Role({required String id}) = _Role;
}
