# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.1.0")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.2")
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
  `package_name` attribute on the generated `dart_library` rule.

- **`# gazelle:resolve dart foo //third_party:foo`** — overrides
  automatic dependency resolution for a Dart package (the `foo` of
  `package:foo/...` imports), mapping it to an explicit Bazel target.

#### pubspec.yaml auto-detection

If a `pubspec.yaml` file is present in the same directory as a `lib/`
folder, Gazelle reads the `name` field and uses it as both the target name
and `package_name` for the generated `dart_library`. This means most
projects need no directives at all.

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
`DartAnalyzableInfo`, so it is an ordinary `dart_analyze_test` operand:

```starlark
dart_analyze_test(name = "analyze_shim", target = "//tools:route_shim")
```

A bare script has no target to point at. Declare a `dart_binary` over the same
source as an analysis handle — it needs no wiring into the `dart_codegen` call,
which keeps running the script exactly as before:

```starlark
dart_binary(name = "my_generator", main = "my_generator.dart")

dart_analyze_test(name = "analyze_my_generator", target = ":my_generator")
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

### Static analysis and formatting

```starlark
load("@rules_dart//dart:defs.bzl", "dart_analyze_test", "dart_format_test")

dart_analyze_test(
    name = "analyze",
    target = ":greeter",
)

dart_format_test(
    name = "format_test",
    target = ":greeter",
    options = "analysis_options.yaml",
)
```

`target` takes a `dart_library` or an executable — `dart_binary`, `dart_test`,
`dart_js_binary`, `dart_wasm_binary`. Pointing it at an executable is how you
lint an entrypoint: a `main.dart` sits outside any package's `lib/`, so no
`dart_library` will accept it, and it would otherwise be the one file in a
project nothing checks. `dart_format_test`'s `target` is the exception — it
takes a `dart_library` only, and formats the sources that library declares.
An executable's `DefaultInfo` is the program it compiles rather than the code
it was built from, so name an entrypoint in `srcs` instead.

Both rules take `options`, and both compute their verdict while building rather
than while testing — a violation fails `bazel build` of the target. Formatting
is configured by the `formatter:` section of an `analysis_options.yaml`
(`page_width`, `trailing_commas`), and `dart_format_test` honours it only when
you name it: the file is not discovered from the surrounding directory, because
the check runs against a staged copy of your sources rather than the sources
themselves. That is deliberate. `dart format` finds its configuration by walking
up from each file it is given, which under Bazel would mean reading files no
target declared and reaching different answers under different sandboxing
settings. Passing `options` is how you opt in; omitting it pins stock defaults.

Use the `dart_analysis_options` target form when the file `include`s a shared
ruleset by `package:` URI, so the packages it resolves against are staged with
it. Sources from external repositories are rejected: a formatting violation in a
module you do not own is a red build no edit in your repo can fix.

Prefer `target` over `srcs` on `dart_format_test`, because the language version
comes with the library — and the language version is what selects the
formatting _style_: below `3.7`, `dart format` writes the old short style, and
from `3.7` on the tall one. Nothing in a staged project can tell the formatter
which applies, so a check that does not carry the version runs at the newest
one the SDK knows, and a package declaring an older version gets told to adopt
a style its own `dart format` will never produce — a red build with no edit
that fixes it. For loose `srcs` that belong to no library, set
`language_version` on the check itself. Setting it alongside `target` is an
error: the library has already answered, and two answers can only disagree.

`dart_fix` applies the analyzer's automated fixes — the same quick-fixes an IDE
offers, driven by the lints your `analysis_options.yaml` enables. Give it the same
`options` target as `dart_analyze_test`, or `bazel run` cannot turn a red analysis
green.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_fix")

dart_fix(
    name = "fix",
    target = ":greeter",
    options = ":analysis_options",
)
```

```sh
bazel run //:fix              # write the fixes into your sources
bazel run //:fix -- --dry-run # print them as a diff, change nothing
```

Generated files are never rewritten: only files Bazel records as sources are
eligible, so codegen output stays resolvable to its importers without being
edited. To inspect what a run would do without applying anything, build the
outputs directly:

```sh
bazel build //:fix --output_groups=+dart_fix_manifest  # what was fixed, and what was skipped
bazel build //:fix --output_groups=+dart_fix_fixes     # the fixed files themselves
```

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

| Example                                               | What it demonstrates                                                                   |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [`hello_world`](e2e/hello_world/)                     | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`)   |
| [`library_deps`](e2e/library_deps/)                   | Transitive `dart_library` dependencies, `srcs` attribute                               |
| [`dart_test`](e2e/dart_test/)                         | Tests with and without deps, `srcs` for test helpers                                   |
| [`analysis`](e2e/analysis/)                           | `dart_analyze_test` and `dart_format_test` with custom and `package:`-included options |
| [`fix`](e2e/fix/)                                     | `dart_fix` write-back, and that generated files are never rewritten                    |
| [`web_app`](e2e/web_app/)                             | JavaScript and WebAssembly compilation with library deps                               |
| [`pub_deps`](e2e/pub_deps/)                           | Single pub.dev package via `pub.package()`                                             |
| [`pub_lock`](e2e/pub_lock/)                           | Multiple packages from `pubspec.lock` via `pub.from_lock()`                            |
| [`gazelle`](e2e/gazelle/)                             | Automatic BUILD file generation with Gazelle                                           |
| [`cross_compile`](e2e/cross_compile/)                 | Cross-compilation to other platforms via `platform_data` transition                    |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                 | `dart_test` with pub dependencies via `pub.from_lock()`                                |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)               | Cross-lock-file package deduplication                                                  |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)           | Version conflict resolution with `on_version_conflict = "upgrade"`                     |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)         | Version conflict detection across lock files                                           |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/) | `pub.from_lock()` across Bazel module boundaries                                       |
| [`codegen`](e2e/codegen/)                             | `dart_codegen`/`dart_aggregate_codegen` over parts, re-exports and source sets         |
| [`ext_exemplar`](e2e/ext_exemplar/)                   | One package per bundled `dart/ext` builder, plus native `code_assets` via sqlite3      |
| [`dual_build`](e2e/dual_build/)                       | Collision detection between Bazel-generated and `build_runner`-generated sources       |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` and `jit-snapshot` are VM formats that ignore target
> flags, and `dart_test` always runs on the host. Linux targets are `linux-x64`,
> `linux-arm64`, `linux-riscv64` and `linux-arm` (armv7, selected by
> `@platforms//cpu:armv7`), reachable from every supported host. Cross-compiling
> fetches SDK artifacts at action time, so it needs network access. See
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
