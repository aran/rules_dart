# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.1.0")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.11.1")
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
> from pub.dev). Packages with `git`, `path`, or `sdk` sources in the lock file
> are skipped. If you have `git` or `path` dependencies, declare them manually
> with `pub.package()` or as local `dart_library` targets.

### BUILD file generation with Gazelle

rules\_dart includes a [Gazelle](https://github.com/bazelbuild/bazel-gazelle)
plugin that generates `BUILD.bazel` files from your Dart source tree.

Add `gazelle` to your `MODULE.bazel`:

```starlark
bazel_dep(name = "gazelle", version = "0.47.0")
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

#### pubspec.yaml auto-detection

If a `pubspec.yaml` file is present in the same directory as a `lib/`
folder, Gazelle reads the `name` field and uses it as both the target name
and `package_name` for the generated `dart_library`. This means most
projects need no directives at all.

### Static analysis and formatting

```starlark
load("@rules_dart//dart:defs.bzl", "dart_analyze_test", "dart_format_test")

dart_analyze_test(
    name = "analyze",
    lib = ":greeter",
)

dart_format_test(
    name = "format_test",
    srcs = glob(["lib/**/*.dart"]),
)
```

### Web compilation

```starlark
load("@rules_dart//dart:defs.bzl", "dart_web_application")

dart_web_application(
    name = "app",
    main = "main.dart",
    deps = [":my_lib"],
)
```

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example | What it demonstrates |
|---------|---------------------|
| [`hello_world`](e2e/hello_world/) | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`) |
| [`library_deps`](e2e/library_deps/) | Transitive `dart_library` dependencies, `srcs` attribute |
| [`dart_test`](e2e/dart_test/) | Tests with and without deps, `srcs` for test helpers |
| [`analysis`](e2e/analysis/) | `dart_analyze_test` with custom `analysis_options.yaml`, `dart_format_test` |
| [`web_app`](e2e/web_app/) | JavaScript and WebAssembly compilation with library deps |
| [`pub_deps`](e2e/pub_deps/) | Single pub.dev package via `pub.package()` |
| [`pub_lock`](e2e/pub_lock/) | Multiple packages from `pubspec.lock` via `pub.from_lock()` |
| [`gazelle`](e2e/gazelle/) | Automatic BUILD file generation with Gazelle |
