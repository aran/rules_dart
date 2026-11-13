# rules_dart examples

One Bazel workspace with a small working example of each rules_dart feature.
Build and test all of them from this directory:

```shell
bazel test //...
```

`MODULE.bazel` starts with the setup every example shares, then has a section
for each directory that needs more; `.bazelrc` is laid out the same way.

| Directory                                  | What it shows                                                              |
| ------------------------------------------ | -------------------------------------------------------------------------- |
| [`hello_world`](hello_world/)              | A binary in every compile mode (`exe`, `aot-snapshot`, `kernel`)           |
| [`library_deps`](library_deps/)            | `dart_library` dependencies, `srcs`, a `dart_package_cycle`                |
| [`tests`](tests/)                          | `dart_test` with and without deps, helpers, `package:test`, coverage       |
| [`analysis`](analysis/)                    | The `dart_analyze` aspect: lints, `package:`-included options, page widths |
| [`shared_lint_rules`](shared_lint_rules/)  | A lint ruleset and page width shared from another Bazel module             |
| [`fix`](fix/)                              | `@rules_dart//dart/fix`, `format` and `unused_deps` writing back           |
| [`codegen`](codegen/)                      | `dart_codegen` and `dart_aggregate_codegen`: parts, re-exports, `srcs_dir` |
| [`builders`](builders/)                    | One package per bundled `build_runner` builder, plus an outside one        |
| [`native_assets`](native_assets/)          | Native code assets: SQLite and webcrypto, built by Bazel                   |
| [`native_hooks`](native_hooks/)            | `record_use`, `hook/link.dart` and data assets via `dart_program_assets`   |
| [`web/app`](web/app/)                      | JavaScript and WebAssembly compilation with library and pub deps           |
| [`web/per_compiler`](web/per_compiler/)    | Per-compiler code by `select()`, and the resets other modules' rules use   |
| [`cross_compile`](cross_compile/)          | Binaries for other platforms, through a `platform_data` transition         |
| [`gazelle`](gazelle/)                      | BUILD files Gazelle generates with the rules_dart plugin                   |
| [`custom_rules`](custom_rules/)            | Your own rules on rules_dart's exported helpers                            |
| [`pub/package`](pub/package/)              | One pub.dev package with `pub.package()`                                   |
| [`pub/lock`](pub/lock/)                    | The packages of a `pubspec.lock` with `pub.from_lock()`, and their purls   |
| [`pub/resolve`](pub/resolve/)              | `resolve`: a `path` package served by a target, a hosted one replaced      |
| [`pub/path`](pub/path/)                    | `path` packages: built from their pubspec, ignored, or refused             |
| [`pub/git`](pub/git/)                      | Git packages at the locked commit and subdirectory                         |
| [`pub/cycle`](pub/cycle/)                  | Pub packages that depend on each other, built as one library               |
| [`fixtures`](fixtures/)                    | Edge cases and regression tests of the examples; not meant as reading      |
