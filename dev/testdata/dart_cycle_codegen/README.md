# dart_cycle_codegen

`order` and `customer` import each other, and `shop/BUILD.bazel` declares them
a cycle. Each has a `@JsonSerializable` model. Each member holds only its
package's own sources. The `json_serializable_codegen` of each depends on both
members and on what they import from outside the cycle, and is visible to the
cycle. The `dart_package_cycle` holds both codegen targets in `srcs`.
