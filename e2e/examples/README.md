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
| [`web/app`](web/app/)             | JavaScript and WebAssembly compilation with library and pub deps          |
| [`cross_compile`](cross_compile/) | Binaries for other platforms, through a `platform_data` transition        |
| [`fixtures`](fixtures/)           | Edge cases and regression tests of the examples; not meant as reading     |
