# rules_dart v0.8.0

Release notes for the `v0.8.0` tag (the tag message is this file). Previous release: 0.7.2 = `3b0470c`.

## Breaking

- `dart_binary` and `dart_test` outputs are the same across clean builds and SDK install paths
- `jit-snapshot` accepts only `-D`, `--enable-experiment`, `--enable-asserts` in `dart_compile_flags`
- Stack traces name libraries by `package:` and `org-dartlang-bazel:///` URIs

## Added

- `--@rules_dart//dart:analyzer_summaries` analyzes each target against its deps' summaries
- `//dart:analyzer_summaries` is on by default; set it to `false` to analyze from source

## Changed

- `dart_binary` and `dart_test` analyze faster in workspaces with many packages
- The `dart_analyze` format check no longer re-runs when only a target's dependencies change
- `dart_test` runfiles hold only the SDK VM; tests running SDK commands add `@rules_dart//dart`
- `dart_test` starts `package:test` tests faster
- `--@rules_dart//dart:test_runner_snapshot=false` runs the `package:test` runner from its kernel
- The `dart_analyze` aspect and web compiles no longer copy pub packages for each target
- `dart_test` compiles each library once and links only the libraries a test reaches
- `--@rules_dart//dart:modular_kernel=false` restores whole-program `dart_test` compiles
- `dart_toolchain` takes an optional `analyze_files` filegroup
- Analysis, `dart fix` and codegen actions take 482 of the SDK's 1,049 files as inputs
- `dart_binary` and `dart_test` no longer copy packages that mix source and generated files
- `//dart:analyzer_summaries` also makes code generators read dependency summaries
- `rules_dart` no longer brings `bazel_lib` or `yaml.bzl` into a build

## Fixed

- `dart_analyze` summary mode analyzes from source when a dependency has no summary
- `dart_analyze` summary mode sees declarations a library exports from a generated file
- `dart_test` builds when a `dart_library` it reaches lists sources that cannot compile alone
- `dart_test` builds when unrelated `dart_library` targets list the same source
- `dart_test` runs its own `main` when a library it imports defines a `main`
- `pub.package` now replaces a locked package in every `pub.from_lock` hub and its dependents
- Exported toolchain and tool defaults resolve against `@rules_dart` when used from external modules
- Generated files in `bazel-out` take precedence over stale source copies in multi-root compiles


## Known issues

- Go/Gazelle not verified: `//gazelle/...`, `//dev/...` and `e2e/gazelle` were
  not built or tested, because the Go SDK cannot be downloaded from the release
  environment. `e2e/gazelle/MODULE.bazel.lock` carries a stale `pub` extension
  entry, and the root and `e2e/ext_exemplar` locks were refreshed without
  re-evaluating Gazelle's `go_deps` extension. Refresh the locks and test the
  root and `e2e/gazelle` on a machine with Go.
- `//dart/ext/sqlite3` and the drift targets were not built (sqlite.org
  unreachable); `e2e/ext_exemplar`'s tests were not run, only its build.
- Verified on Linux only; macOS and Windows were not run.
- Tagged on Mivr/rules_dart only; not published to the BCR or pub.dev.
