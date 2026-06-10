# dart_built_value

Fixture guarding interface-driven built_value detection. Idiomatic
built_value classes carry no annotation — the codegen trigger is the
`implements Built<T, TBuilder>` clause (see
`e2e/ext_exemplar/built_value/lib/user.dart`). Gazelle must emit a
`built_value_library` macro for such files, exactly as if they carried
a registered annotation.
