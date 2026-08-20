import 'package:built_collection/built_collection.dart';
import 'package:built_value/serializer.dart';
import 'package:built_value/standard_json_plugin.dart';
import 'package:built_value_sample/profile.dart';

part 'serializers.g.dart';

// @SerializersFor drives built_value_generator to produce `_$serializers`
// with a registered Serializer<T> for each listed type plus every
// collection/primitive they transitively reference (here
// BuiltList<String>, String, int).

/// The generated serializer registry for the fixture's models.
@SerializersFor([Profile])
final Serializers serializers = _$serializers;

// Layered: `standardSerializers` adds StandardJsonPlugin on top so
// consumers get JSON-flavored output (Map / List of primitives) rather
// than built_value's canonical "wire" representation.

/// [serializers] with [StandardJsonPlugin] layered on top.
final Serializers standardSerializers =
    (serializers.toBuilder()..addPlugin(StandardJsonPlugin())).build();
