# dart_first_party_macro_resolution

Fixture guarding first-party resolution of packages built with
convenience macros. `Imports()` must index macro kinds (e.g.
`json_serializable_library`) — not just `dart_library` — under both the
rule name and the `package_name` attr, so a sibling package importing
`package:models/models.dart` resolves to `//models` instead of being
treated as an external pub dependency.
