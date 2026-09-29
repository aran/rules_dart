# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.1.0")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.4")
use_repo(dart, "dart_toolchains")

register_toolchains("@dart_toolchains//:all")
```

## Usage

### Running the Dart SDK

No separate Dart SDK installation is needed. The toolchain downloads the SDK
automatically. To run the `dart` CLI directly:

```shell
bazel run @rules_dart//dart -- --version
bazel run @rules_dart//dart -- analyze lib/
bazel run @rules_dart//dart -- format lib/
```

> **Tip**: Consider using [`bazel_env`](https://github.com/buildbuddy-io/bazel_env.bzl)
> to put Bazel-managed tool binaries on your `PATH` for IDE and shell use.

### Rules

```starlark
load("@rules_dart//dart:defs.bzl", "dart_library", "dart_binary", "dart_test")

dart_library(
    name = "greeter",
    srcs = glob(["lib/**/*.dart"]),
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    deps = [":greeter"],
)

dart_test(
    name = "greeter_test",
    main = "test/greeter_test.dart",
    deps = [":greeter"],
)
```

### Tests

A `dart_test` whose `deps` include `package:test` runs under `package:test`'s
own runner, built from that same package, so Bazel's test features work:

- `bazel test --test_filter=<regex>` runs the cases whose names match.
- `shard_count` splits a file's cases across shards.
- Each case appears in Bazel's test report (`test.xml`).
- Bazel's `size`/`timeout` is the only time limit. `package:test`'s default
  30-second limit per case is switched off; a `timeout:` a test states on a
  case still applies.

`package:test` must be a direct entry in `deps` (for example `@deps//:test`),
not reached only through a helper library: the runner comes with that target.
A test whose `main` does not use `package:test` runs directly, and fails if
given a filter or shards, because it has no cases to select.

### Using pub.dev packages

Declare individual packages with `pub.package()`:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.package(
    name = "path",
    version = "1.9.1",
    sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5",
)
use_repo(pub, "path")
```

Then depend on them in your targets:

```starlark
dart_binary(
    name = "app",
    main = "main.dart",
    deps = ["@path//:path"],
)
```

For projects with many dependencies, use `pub.from_lock()` to import all
packages from a `pubspec.lock` file at once:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
```

Each hosted package is downloaded into its own external repository for better
caching and parallelism. Packages are available as `@pub_deps//:package_name`:

```starlark
dart_binary(
    name = "app",
    main = "main.dart",
    deps = [
        "@pub_deps//:path",
        "@pub_deps//:collection",
    ],
)
```

> **Note**: `pub.from_lock()` only resolves **hosted** packages (i.e. packages
> from a pub registry such as pub.dev). Packages with `git`, `path`, or `sdk`
> sources in the lock file are skipped: no repository is created for them, so
> `package:` imports of those packages fail to resolve unless they are provided
> another way. `sdk` packages (e.g. Flutter's) come from the SDK itself, not
> pub. For `git` or `path` dependencies, declare them with `pub.package()` or
> as local `dart_library` targets. Each `from_lock()` prints one summary of
> everything it skipped, grouped by source.

### BUILD file generation with Gazelle

rules_dart includes a [Gazelle](https://github.com/bazelbuild/bazel-gazelle)
plugin that generates `BUILD.bazel` files from your Dart source tree.

Add `gazelle` to your `MODULE.bazel`:

```starlark
bazel_dep(name = "gazelle", version = "0.50.0")
```

Then create a root `BUILD.bazel` with the Gazelle targets:

```starlark
load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = [
        "@rules_dart//gazelle/dart",
    ],
)

gazelle(
    name = "gazelle",
    gazelle = "gazelle_bin",
)
```

Run Gazelle to generate or update BUILD files:

```shell
bazel run //:gazelle
```

Gazelle will scan `lib/`, `bin/`, and `test/` directories, emitting
`dart_library`, `dart_binary`, and `dart_test` targets respectively. It
resolves `import` statements to determine `deps`, including support for
`show` and `deferred` import modifiers.

#### Directives

Add directives as comments in a `BUILD.bazel` file to control generation:

- **`# gazelle:dart_pub_deps_repo pub_deps`** — tells Gazelle which
  external repository holds pub.dev packages. Imports like
  `package:shelf/shelf.dart` are resolved to `@pub_deps//:shelf`.

- **`# gazelle:dart_package_name my_app`** — explicitly sets the
  `package_name` attribute on the generated `dart_library` rule. In a directory
  that already declares a `dart_package_metadata`, Gazelle emits
  `package = ":pkg"` on the rules it generates instead of an inline
  `package_name`, and warns when the declaration's name differs from the one the
  pubspec or this directive supplies.

- **`# gazelle:resolve dart foo //third_party:foo`** — overrides
  automatic dependency resolution for a Dart package (the `foo` of
  `package:foo/...` imports), mapping it to an explicit Bazel target.

#### pubspec.yaml auto-detection

If a `pubspec.yaml` file is present in the same directory as a `lib/`
folder, Gazelle reads the `name` field and uses it as both the target name
and `package_name` for the generated `dart_library`. This means most
projects need no directives at all.

#### Analysis options

For every directory holding an `analysis_options.yaml`, Gazelle emits a
`dart_analysis_options` named `analysis_options` (`analysis_options_yaml` if
another rule in that directory has the name) whose `deps` are the packages its
`include: package:<pkg>/...` lines name. In the root package it keeps one
`dart_analysis_config` named `analysis_config` listing all of them, which is the
target the `analysis_config` flag points at. A run on part of the tree
(`gazelle path/to/dir`, or `-r=false`) updates only the directories it visits
and keeps the config's other entries, so `gazelle -mode=diff` over the whole
repository in CI reports an `analysis_options.yaml` nobody listed.

### Code generation

`dart_codegen` runs a generator on each source file individually.
`dart_aggregate_codegen` runs a generator over all sources at once (for
generators like auto_route or injectable that need a whole-package view).

```starlark
load("@rules_dart//dart:defs.bzl", "dart_codegen", "dart_aggregate_codegen")

# One target per input file; outputs are the input's stem plus each suffix.
dart_codegen(
    name = "user_g",
    src = "lib/user.dart",
    package_name = "my_pkg",
    generator_bin = "@rules_dart//dart/ext/json_serializable:shim",
    output_suffixes = [".json_serializable.g.part"],
    deps = [
        ":models",                      # same-package siblings
        "@pub_deps//:json_annotation",  # import source
    ],
)

dart_aggregate_codegen(
    name = "routes",
    srcs = glob(["lib/**/*.dart"]),
    package_name = "my_pkg",
    generator_bin = "//tools:route_shim",
    outputs = ["lib/router.gr.dart"],
    deps = [":my_lib"],
)
```

Both rules take the generator either way. `generator_bin` is a target: a
`dart_binary` speaking the shim CLI contract, run as a persistent worker (see
[`docs/ext.md`](./docs/ext.md)). `generator`/`generator_script` is a bare
`.dart` file run as `dart <script>` with no package resolution of its own, so it
can import `dart:` core libraries and nothing else — fine for a throwaway
emitter, insufficient for anything with dependencies.

That distinction is also what analyzing a generator comes down to. A
`generator_bin` is already a target, and every executable rule hands out
`DartAnalyzableInfo`, so the `dart_analyze` aspect checks it like any other
target (see [Static analysis](#static-analysis-and-formatting)).

A bare script has no target to be checked as. Declare a `dart_binary` over the
same source as an analysis handle — it needs no wiring into the `dart_codegen`
call, which keeps running the script exactly as before:

```starlark
dart_binary(name = "my_generator", main = "my_generator.dart")
```

Do not promote a script to `generator_bin` just to analyze it: that path runs
its executable as a persistent worker, which a plain `dart_binary` does not
speak. The model files a generator reads need nothing special — they belong to
the `dart_library` targets in `deps`, which are analyzable already.

For first-party builders (`json_serializable`, `freezed`, `built_value`,
`mockito`, `go_router`, `copy_with_extension_gen`, `injectable`, `stacked`,
`drift`), each ships a convenience macro (`json_serializable_library`,
`freezed_library`, …) under `dart/ext/<builder>/defs.bzl`. Gazelle discovers
the matching annotations in sources and emits the macro automatically. See
[`docs/ext.md`](./docs/ext.md) for the shim contract, worker behaviour, and
dual-build migration guide when coexisting with `build_runner`.

#### Stating a package's name once

Every rule that builds part of a package must agree on its `package_name` and
`language_version`: the `dart_codegen` above states them, and the `dart_library`
collecting its output has to state the same pair. A `dart_package_metadata`
target declares them once and the rules point at it:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_codegen", "dart_library", "dart_package_metadata")

dart_package_metadata(
    name = "pkg",
    package_name = "my_pkg",
    language_version = "3.11",
)

dart_codegen(
    name = "user_g",
    src = "lib/user.dart",
    package = ":pkg",
    generator = "//tools:gen.dart",
    output_suffixes = [".g.dart"],
)

dart_library(
    name = "my_lib",
    srcs = ["lib/user.dart", ":user_g"],
    package = ":pkg",
)
```

Set `package` or the inline attributes, never both — the rules refuse the
overlap rather than silently ignoring one. Because it is a target rather than a
macro, the rules referencing it can sit in different BUILD files, which is the
case nothing else covers. The builder macros (`json_serializable_library` and
friends) accept `package` too and forward it to every rule they emit.

This is not `pub.package()`, which fetches a published package from pub.dev;
`dart_package_metadata` states facts about a package you are building yourself.

#### Executables in a package

A `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary` belongs to
no package unless it says so, and usually need not: its entrypoint takes the
language version of the package whose root directory contains it, as Dart does
for `bin/` and `test/`. A package with no `dart_library` has nothing to state
that version, so an executable may state it itself, with the same `package`, or
inline `package_name` / `language_version`, that a library takes:

```starlark
dart_binary(
    name = "tool",
    main = "bin/tool.dart",
    language_version = "3.6",
)
```

It is then a member of that package, rooted at its BUILD file's directory as a
`dart_library` there would be: the entrypoint compiles, analyzes and is
format-checked at that version. The package name defaults to the directory's
name. Everything it states must agree with its `deps`, or the build fails
naming both sides: a library of the same package (same directory) must state
the same name and the same `language_version`; a package in `deps` with the
same name must be rooted in the same directory; and each of the executable's
own files must sit in its directory and not inside another package's.

### Static analysis and formatting

`dart analyze` and the `dart format` check run as an aspect, `dart_analyze`,
over every Dart target a `bazel test` names. Enable it in `.bazelrc`, and list
every `analysis_options.yaml` in the repository in one `dart_analysis_config`:

```
# .bazelrc
test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
test --output_groups=+dart_analyze
test --output_groups=+dart_format
common --@rules_dart//dart:analysis_config=//:analysis_config
```

Each check is its own output group: keep the `dart_analyze` line for analysis,
the `dart_format` line for the format check, or both. A check whose group is
not requested does not run.

```starlark
# BUILD.bazel
load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")

dart_analysis_options(
    name = "analysis_options",
    src = "analysis_options.yaml",
    deps = ["@very_good_analysis"],  # packages its `include:` names
)

dart_analysis_config(
    name = "analysis_config",
    options = [
        ":analysis_options",
        "//tools:analysis_options",  # tools/analysis_options.yaml
    ],
)
```

Each file is judged by the nearest listed `analysis_options.yaml` above it, as
in the IDE, so every listed file must have that name. An options file may
`include:` another listed one by relative path (`include:
../analysis_options.yaml`). Any other yaml it includes comes from a package, by
`package:` URI, with that package in the `dart_analysis_options`'s `deps`: only
listed options files and those packages are staged, so a relative include of
any other file fails both checks rather than reading a file no target
declares. `bazel test //...` then
analyzes every Dart target it matches, and any diagnostic, down to an info,
fails the build. Only each target's own hand-written files are checked: its
dependencies are resolved but not re-checked (each is checked as a target of
its own), generated files are never checked, and targets in other repositories
(pub packages, other Bazel modules) are left to the module that owns them.
Options files from other repositories are refused; to share a ruleset across
modules, `include:` it from an options file of your own and put its package in
that `dart_analysis_options`'s `deps`. Tag a target `no-dart-analyze` to skip
its analysis, and `no-dart-format` to skip its format check; each tag leaves
the other check in place.

A `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary` has its
entrypoint checked, which is how you lint a `main.dart`: it sits outside any
package's `lib/`, so no `dart_library` will accept it, and it would otherwise be
the one file in a project nothing checks.

The format check runs `dart format --set-exit-if-changed` over the same files,
and fails the build if formatting would change any of them. Its settings are
the `formatter:` section (`page_width`, `trailing_commas`) of the same nearest
listed `analysis_options.yaml`, including what that file `include:`s, and a
file under no listed options file gets stock defaults. Options files the
config does not list are never read, whatever directory they sit in: the check
runs against a staged copy of your sources, not the sources themselves, so the
verdict cannot depend on files no target declares or on sandboxing settings.
If an options file cannot be read — an `include:` that does not resolve — the
check fails rather than quietly formatting at stock defaults, as `dart format`
itself would.

The language version selects the formatting _style_: below `3.7`, `dart format`
writes the old short style, and from `3.7` on the tall one. The check formats
each target at its own package's `language_version` (set on the `dart_library`
or its `dart_package_metadata`; Gazelle copies it from `pubspec.yaml`). An
executable's entrypoint takes the version of the package whose directory
contains it, as Dart does for `bin/` and `test/`, or the one the executable
states for itself (see [Executables in a package](#executables-in-a-package)). With no version stated, the
check uses the newest the SDK knows, so a package on an older version must
state it for the check to hold it to the style its own `dart format` produces.

`dart_format` is the check's `bazel run` counterpart: it rewrites files in your
workspace with the settings the check applies to them. It reads the same
`analysis_config`, which is why that flag goes under `common`, and stages the
options exactly as the check does, so each file gets its nearest listed
options file. Running the SDK's formatter over the workspace directly
(`bazel run @rules_dart//dart -- format`) cannot resolve an `include:` by
`package:` URI, because there is no package config for it to use, and the SDK
then ignores every key in the options file, not only the included ones.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_format")

dart_format(name = "format")
```

```sh
bazel run //:format -- lib test  # files or directories, relative to where you run it
```

It formats at the newest language version the SDK knows unless you pass
`--language-version=<major>.<minor>`. The check uses each target's own
version, so pass it when formatting a package below `3.7`. Files outside the
workspace are refused: no listed options could govern them.

`dart_fix` applies the analyzer's automated fixes — the same quick-fixes an IDE
offers, driven by the lints your options enable. It fixes its target's own
files over the very project the `dart_analyze` aspect stages to analyze them,
under the same `analysis_config`, which is why that flag goes under `common`:
`bazel run` then sees the options `bazel test` checks against.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_fix")

dart_fix(
    name = "fix",
    target = ":greeter",
)
```

```sh
bazel run //:fix              # write the fixes into your sources
bazel run //:fix -- --dry-run # print them as a diff, change nothing
```

Generated files are never rewritten: only files Bazel records as sources are
eligible, so codegen output stays resolvable to its importers without being
edited. A target tagged `no-dart-analyze` can still be fixed. To inspect what a
run would do without applying anything, build the outputs directly:

```sh
bazel build //:fix --output_groups=+dart_fix_manifest  # what was fixed, and what was skipped
bazel build //:fix --output_groups=+dart_fix_fixes     # the fixed files themselves
```

#### Checking targets `//...` does not reach

The `.bazelrc` setup checks the targets a test run names, so it never reaches a
target tagged `manual`, or a fixture that must not be built by a wildcard.
`dart_analysis_test` applies the same aspect to the targets it lists:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_analysis_test")

dart_analysis_test(
    name = "fixtures_analysis_test",
    targets = [":manual_fixture"],
)
```

Both checks run on each listed target, less what its `no-dart-analyze` or
`no-dart-format` tag removes, under the same `analysis_config` flag, whatever
output groups the command line asks for. A violation fails the build of the
test. It is not the way to enable the checks — the `.bazelrc` setup is — only
the way to reach what that setup cannot name.

### Web compilation

`dart_js_binary` compiles a Dart entrypoint to JavaScript via `dart compile js`.
`dart_wasm_binary` compiles to WebAssembly via `dart compile wasm` (requires a
browser with WasmGC support).

```starlark
load("@rules_dart//dart:defs.bzl", "dart_js_binary", "dart_wasm_binary")

dart_js_binary(
    name = "app",
    main = "main.dart",
    deps = [":my_lib"],
)

dart_wasm_binary(
    name = "app_wasm",
    main = "main.dart",
    deps = [":my_lib"],
)
```

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example                                               | What it demonstrates                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [`hello_world`](e2e/hello_world/)                     | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`) |
| [`library_deps`](e2e/library_deps/)                   | Transitive `dart_library` dependencies, `srcs` attribute                             |
| [`dart_test`](e2e/dart_test/)                         | Tests with and without deps, `srcs` for test helpers                                 |
| [`analysis`](e2e/analysis/)                           | The `dart_analyze` aspect's checks with `package:`-included options                  |
| [`fix`](e2e/fix/)                                     | `dart_fix` write-back, and that generated files are never rewritten                  |
| [`analyze_composition`](e2e/analyze_composition/)     | A lint ruleset shared from another Bazel module                                      |
| [`web_app`](e2e/web_app/)                             | JavaScript and WebAssembly compilation with library deps                             |
| [`pub_deps`](e2e/pub_deps/)                           | Single pub.dev package via `pub.package()`                                           |
| [`pub_lock`](e2e/pub_lock/)                           | Multiple packages from `pubspec.lock` via `pub.from_lock()`                          |
| [`gazelle`](e2e/gazelle/)                             | Automatic BUILD file generation with Gazelle                                         |
| [`cross_compile`](e2e/cross_compile/)                 | Cross-compilation to other platforms via `platform_data` transition                  |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                 | `dart_test` with pub dependencies via `pub.from_lock()`                              |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)               | Cross-lock-file package deduplication                                                |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)           | Version conflict resolution with `on_version_conflict = "upgrade"`                   |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)         | Version conflict detection across lock files                                         |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/) | `pub.from_lock()` across Bazel module boundaries                                     |
| [`codegen`](e2e/codegen/)                             | `dart_codegen`/`dart_aggregate_codegen` over parts, re-exports and source sets       |
| [`ext_exemplar`](e2e/ext_exemplar/)                   | One package per bundled `dart/ext` builder, plus native `code_assets` via sqlite3    |
| [`dual_build`](e2e/dual_build/)                       | Collision detection between Bazel-generated and `build_runner`-generated sources     |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` and `jit-snapshot` are VM formats that ignore target
> flags, and `dart_test` always runs on the host. Linux targets are `linux-x64`,
> `linux-arm64`, `linux-riscv64` and `linux-arm` (armv7, selected by
> `@platforms//cpu:armv7`), reachable from every supported host. Cross-compiling
> fetches SDK artifacts at action time, so it needs network access. See
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
