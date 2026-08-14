import 'package:json_annotation/json_annotation.dart';

import 'base.dart';

part 'cross_user.g.dart';

// Cross-file resolution: the @JsonSerializable class implements a type
// declared in base.dart. The shim's Resolver has to walk the sibling
// file to resolve `Identifiable` at analysis time. That walking is
// wired by `dart_codegen`'s `same_package_library_dep_files`
// auto-staging: the `:base` dart_library in BUILD.bazel exposes
// base.dart through DartInfo so the codegen action sees it as a
// `--dep` sibling.
@JsonSerializable()
class CrossUser implements Identifiable {
  CrossUser({required this.id, required this.name});

  factory CrossUser.fromJson(Map<String, dynamic> json) =>
      _$CrossUserFromJson(json);

  @override
  final String id;
  final String name;

  Map<String, dynamic> toJson() => _$CrossUserToJson(this);
}
