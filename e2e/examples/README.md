# rules_dart examples

One Bazel workspace with a small working example of each rules_dart feature.
Build and test all of them from this directory:

```shell
bazel test //...
```

`MODULE.bazel` starts with the setup every example shares, then has one
section for each directory that needs more.

| Directory                        | What it shows                                                            |
| -------------------------------- | ------------------------------------------------------------------------ |
| [`hello_world`](hello_world/)     | A binary in every compile mode (`exe`, `aot-snapshot`, `kernel`)          |
| [`library_deps`](library_deps/)   | `dart_library` dependencies, `srcs`, a `dart_package_cycle`               |
| [`tests`](tests/)                 | `dart_test` with and without deps, helpers, `package:test`, coverage      |
| [`analysis`](analysis/)           | The `dart_analyze` aspect: lints, `package:`-included options, page widths |
| [`shared_lint_rules`](shared_lint_rules/) | A lint ruleset and page width shared from another Bazel module   |
| [`codegen`](codegen/)             | `dart_codegen` / `dart_aggregate_codegen`: parts, re-exports, `srcs_dir`  |
| [`fix`](fix/)                     | `@rules_dart//dart/fix`, `format` and `unused_deps` write-back            |
| [`web/app`](web/app/)             | JavaScript and WebAssembly compilation with library and pub deps          |
| [`web/per_compiler`](web/per_compiler/) | Per-compiler code by `select()`, and the resets other modules' rules use |
| [`cross_compile`](cross_compile/) | Binaries for other platforms, through a `platform_data` transition        |
| [`fixtures`](fixtures/)           | Edge cases and regression tests of the examples; not meant as reading     |
