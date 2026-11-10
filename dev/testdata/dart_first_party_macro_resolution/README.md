# dart_first_party_macro_resolution

Fixture guarding first-party resolution of a package whose only source
carries an annotation. Its `dart_library` holds the source and what the
`json_serializable_codegen` macro generates, so a sibling package importing
`package:models/models.dart` resolves to `//models` instead of being
treated as an external pub dependency.
