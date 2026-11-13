// INTENTIONALLY-WRONG stale fixture — never what rules_dart produces.

part of 'user.dart';

User _$UserFromJson(Map<String, dynamic> json) =>
    User(name: 'STALE_NAME', age: -999, tags: const ['STALE_TAG']);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
      'name': 'STALE_NAME',
      'age': -999,
      'tags': const ['STALE_TAG'],
    };
