# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.1.0")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.7")
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

It runs in the directory `bazel run` was invoked from, and, like every build
action, with Dart's analytics off, so it writes nothing into your home
directory.

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

Like any Bazel test, a `dart_test` is built for the target platform, native
`code_assets` and the Dart VM included, and runs on a host matching it. To run
tests on another host, a remote Linux executor say, build them for that host's
platform: with `--platforms`, or per test with a platform transition such as
`platform_transition_test` from `aspect_bazel_lib`.

A test carries only the part of the Dart SDK that runs its compiled code: the
`dart` launcher and the VM. A test that runs SDK commands itself, such as
`dart compile` or `dart analyze`, adds `@rules_dart//dart` to its `data`, which
brings the whole SDK, and runs that target's launcher (found with
`$(rlocationpath @rules_dart//dart)`) as it would `dart`:

```starlark
dart_test(
    name = "cli_test",
    args = ["$(rlocationpath @rules_dart//dart)"],
    data = ["@rules_dart//dart"],
    main = "test/cli_test.dart",
)
```

Each library is compiled once into kernel modules that every test reaching it
links. A library's dependents compile against its modules' outlines, which
leave out function bodies, so an edit inside a body recompiles that library
alone, plus the links of the tests that reach it. In a file that declares a
mixin, an edit that moves code also recompiles the library's dependents. The
outlines are made with the SDK source of the Dart version rules_dart pins. With
an SDK whose kernel format differs, the build fails and says so; turn them off
with `--@rules_dart//dart:outline_kernel=false`, and dependents compile against
full kernels.

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
caching and parallelism, and only when something builds it. Each archive is
verified against the `sha256` the lock records; a lock written by a pub older
than 2.19 has none and is refused, so run `dart pub get` to rewrite it. Every
package the lock names is available as `@pub_deps//:package_name`, including one
you also declare with `pub.package()`, which then supplies it:

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

> **Note**: `pub.from_lock()` resolves **hosted** packages (from a pub
> registry such as pub.dev) and **git** packages. A git package is fetched at
> the commit the lock records as `resolved-ref`, which must be a full 40-digit
> commit id, and is served from the lock's `path` within the repository. The
> fetch uses the host's `git` (2.14 or newer, as `dart pub get` needs) with the
> host's configuration, so credentials and `insteadOf` mirrors work; the files
> are written with none of it (no line-ending conversion, filters or hooks), so
> every machine gets the same bytes. The client's `GIT_*` variables are unset
> throughout. A server that will not fetch a commit by its id is asked for
> every ref it advertises instead, as pub does. Packages with `path` or `sdk`
> sources are skipped: no repository is created for them, so `package:`
> imports of those packages fail to resolve unless they are provided another
> way. `sdk` packages (e.g. Flutter's) come from the SDK itself, not pub. For
> `path` dependencies, declare them with `pub.package()` or as local
> `dart_library` targets. Each `from_lock()` prints one summary of everything
> it skipped, grouped by source.
> A fetched package that depends on a skipped one (a `dependency_overrides`
> path package, say) fails when it is fetched, naming the dependency, rather
> than building without it.

Each package's `pubspec.yaml` is read with `package:yaml`, as pub reads it, by
a small reader rules_dart compiles once per host with its Dart SDK. A pubspec
pub would refuse (a `sdk:` constraint written as a number, say) fails the fetch
with pub's message, naming the package. Rule sets of your own read pubspecs the
same way, in a repository rule, with `read_pubspec` from
`@rules_dart//dart/pub:pubspec.bzl`.

Packages that depend on each other, which pub allows (`dio` and
`dio_web_adapter`), are built as one library, each keeping its own name and
language version; `@pub_deps//:dio` and `@pub_deps//:dio_web_adapter` both name
it.

rules_dart builds one version of each package, and the root module decides it,
as Bazel's root module decides everything else: a `pub.package()` in the root
wins over the root's locks, and either wins over a `pub.package()` in a module
the root depends on, whose `@name` repository then supplies the root's version.
If two such modules declare different versions and the root states none, the
build fails naming both; pin the package in the root with `pub.package()` or
its lock.

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
generators like auto_route that need a whole-package view).

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
`mockito`, `go_router`, `copy_with_extension_gen`, `stacked`,
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

#### Analysis workers

Analysis and fixes run in Bazel persistent workers. Each worker keeps one Dart
analysis server for the requests of a build, so the server's start and its
analysis of the SDK are paid once per worker instead of once per target. The
server stops once its worker has had no request for a minute; the worker itself
(a small process) stays with Bazel's server. Each request is analyzed afresh:
the result is what `dart analyze` would print for the same files.

To run a fresh `dart analyze` and `dart fix` per action instead:

```sh
bazel test //... --@rules_dart//dart:analysis_worker=false
```

Bazel's own worker flags apply: `--worker_max_instances=DartAnalyze=N` sets
how many servers run at once (each holds a few hundred MB), and
`--strategy=DartAnalyze=sandboxed`, or remote execution, runs each action once
on its own server. On Windows a worker that is killed, rather than stopped by
Bazel, leaves its server running until Bazel's server shuts down.

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

#### Per-compiler code

Dart picks native or web code itself, with a conditional import on
`dart.library.js_interop`. What it cannot do is give dart2js and dart2wasm
different declared types or different files. For that, the runtime is a
constraint of the target platform, `@rules_dart//dart/constraints:runtime`:
`js` (dart2js and DDC), `wasm` (dart2wasm), or `vm`, the default, which every
platform that does not mention it carries, the host included. Each web binary
builds everything it depends on for a platform carrying its compiler,
`@rules_dart//dart/platforms:js` or `:wasm` unless its `platform` attribute
names one of your own. A library picks a variant with a `select()` in its
`deps`:

```starlark
dart_library(
    name = "vec",
    srcs = ["lib/vec.dart"],  # import 'package:i64/i64.dart';
    deps = select({
        "@rules_dart//dart/constraints:js": ["//i64/js:i64"],
        "@rules_dart//dart/constraints:wasm": ["//i64/typed:i64"],
        "//conditions:default": ["//i64/typed:i64"],
    }),
)
```

The variants are separate `dart_library` targets with the same `package_name`,
each in its own directory, so the import is the same whichever is picked.
Building `:app` or `:app_wasm` builds only that binary's variant.

A platform of your own carries the compiler's constraint value, and whatever
constraints of yours a `select()` needs beside it. Give it no `flags`: they
stay set beneath the binary, in the code it shares with VM builds, which is
then built twice.

```starlark
platform(
    name = "wasm_threads",
    parents = ["@rules_dart//dart/platforms:wasm"],
    constraint_values = [":threads"],
)

dart_wasm_binary(
    name = "app_wasm_threads",
    main = "bin/main.dart",
    platform = ":wasm_threads",
    deps = [":vec"],
)
```

Code generators cannot vary by compiler: `dart_codegen` and its siblings are
built for the platform the build had before any web binary, so their outputs
are shared by both binaries and the VM. A generator that needs per-compiler
output emits every variant, one `dart_codegen` per variant directory, and the
library above chooses.

Code with no variant for the VM (it imports `dart:js_interop` unconditionally,
say) says so in `target_compatible_with`: incompatible where the runtime
is `vm`. Then `bazel build //...` skips it on the host, and a VM program
reaching it is incompatible too. Code with no variant for the web says
`target_compatible_with = ["@rules_dart//dart/constraints:vm"]`. `bazel test
//...` never analyses web-only code; a `dart_analysis_test` with
`web_platforms` does:

```starlark
dart_library(
    name = "interop",
    srcs = ["lib/interop.dart"],
    target_compatible_with = select({
        "@rules_dart//dart/constraints:vm": ["@platforms//:incompatible"],
        "//conditions:default": [],
    }),
    deps = select({
        "@rules_dart//dart/constraints:js": [":js_impl"],
        "@rules_dart//dart/constraints:wasm": [":wasm_impl"],
    }),
)

dart_analysis_test(
    name = "interop_analysis_test",
    targets = [":interop"],
    web_platforms = [
        "@rules_dart//dart/platforms:js",
        "@rules_dart//dart/platforms:wasm",
    ],
)
```

Only the libraries on the path from a binary to such a `select()` are
configured once per compiler; they run no actions. Pub packages, codegen and
native code assets go back to the build's own platform and are built once. A
hand-written library that cannot reach per-compiler code may say so with
`runtime_independent = True`, as every pub package does, and is built once
too.

A rule set that builds Dart for a web platform uses the transitions in
`@rules_dart//dart:utils.bzl` (`web_platform_transition`,
`web_platforms_transition`, or `web_platform_settings` in a transition of its
own), never `--platforms` alone: they record the platform the build had, which
is what the resets go back to. Its split may see fewer keys in
`ctx.split_attr` than it returned: branches that a dependency's reset brings to
one configuration arrive as one key. Its analysis tests take
`config_settings = web_platform_config_settings(platform)`, the same settings
as a fixed dict.

### Recorded uses and link hooks

A package can ship a `hook/link.dart` that decides what to include from how the
program uses the package: the compiler records each constant instance of a
`@RecordUse` class (and each constant call to a `@RecordUse` static method)
that survives tree-shaking. `dart_binary(record_use = True)` writes those uses
beside the executable, and `dart_link_hook` runs the link hooks in its `deps`
over them and collects the data assets they emit.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_library", "dart_link_hook")

dart_library(
    name = "glyphs",
    srcs = glob(["lib/**/*.dart"]),
    link_hook = "hook/link.dart",
    deps = ["@pub_deps//:data_assets", "@pub_deps//:hooks", "@pub_deps//:meta", "@pub_deps//:record_use"],
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    record_use = True,
    deps = [":glyphs"],
)

dart_link_hook(
    name = "app_assets",
    data_assets = ["package:glyphs/glyphs/index.json"],
    recorded_uses = ":app",
    deps = [":glyphs"],
)
```

Uses are recorded in the `exe` and `aot-snapshot` modes; in `kernel` and
`jit-snapshot` the hooks see none. The data assets a hook emits are declared by
id in `data_assets`, since Bazel names every output before the hooks run; the
build fails if a hook emits a different set, or if it fails itself, with the
hook's message. Pub packages that ship a link hook get `link_hook` set by
`pub.from_lock()`.

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example                                                 | What it demonstrates                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [`hello_world`](e2e/hello_world/)                       | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`)     |
| [`library_deps`](e2e/library_deps/)                     | Transitive `dart_library` dependencies, `srcs` attribute                                 |
| [`dart_test`](e2e/dart_test/)                           | Tests with and without deps, `srcs` for test helpers                                     |
| [`analysis`](e2e/analysis/)                             | The `dart_analyze` aspect's checks with `package:`-included options                      |
| [`fix`](e2e/fix/)                                       | `dart_fix` write-back, and that generated files are never rewritten                      |
| [`analyze_composition`](e2e/analyze_composition/)       | A lint ruleset shared from another Bazel module                                          |
| [`web_app`](e2e/web_app/)                               | JavaScript and WebAssembly compilation with library deps                                 |
| [`web_compiler`](e2e/web_compiler/)                     | Per-compiler code by `select()`, and the resets other modules' rules use                 |
| [`pub_deps`](e2e/pub_deps/)                             | Single pub.dev package via `pub.package()`                                               |
| [`pub_lock`](e2e/pub_lock/)                             | Multiple packages from `pubspec.lock` via `pub.from_lock()`                              |
| [`gazelle`](e2e/gazelle/)                               | Automatic BUILD file generation with Gazelle                                             |
| [`cross_compile`](e2e/cross_compile/)                   | Cross-compilation to other platforms via `platform_data` transition                      |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                   | `dart_test` with pub dependencies via `pub.from_lock()`                                  |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)                 | Cross-lock-file package deduplication                                                    |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)             | Version conflict resolution with `on_version_conflict = "upgrade"`                       |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)           | Version conflict detection across lock files                                             |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/)   | `pub.from_lock()` across Bazel module boundaries                                         |
| [`pub_lock_cycle`](e2e/pub_lock_cycle/)                 | Packages that depend on each other (`dio`, `dio_web_adapter`), on the VM and the web     |
| [`pub_member_kind`](e2e/pub_member_kind/)               | Another rule set's own pub package kind, in a cycle, over the public pub surface         |
| [`pub_lock_path_override`](e2e/pub_lock_path_override/) | A hosted package depending on a path package fails, naming it                            |
| [`pub_hub_surface`](e2e/pub_hub_surface/)               | Every locked package in its hub, including one declared with `pub.package()`             |
| [`pub_override_root_lock`](e2e/pub_override_root_lock/) | The root's lock wins over a dependency module's `pub.package()`                          |
| [`pub_package_conflict`](e2e/pub_package_conflict/)     | Two dependency modules' differing `pub.package()`s fail, naming both                     |
| [`codegen`](e2e/codegen/)                               | `dart_codegen`/`dart_aggregate_codegen` over parts, re-exports and source sets           |
| [`ext_exemplar`](e2e/ext_exemplar/)                     | One package per bundled `dart/ext` builder, plus native `code_assets`, sqlite3/webcrypto |
| [`dual_build`](e2e/dual_build/)                         | Collision detection between Bazel-generated and `build_runner`-generated sources         |
| [`link_hook`](e2e/link_hook/)                           | `record_use` and a package's `hook/link.dart` emitting a data asset via `dart_link_hook` |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` and `jit-snapshot` are VM formats that ignore target
> flags. Built natively, a `kernel`, `jit-snapshot` or `aot-snapshot` target's
> executable is a launcher that runs the output in the SDK's VM, so it works with
> `bazel run` and as `data`; cross-compiled, the target's executable is the
> output itself, for the target's own runtime to run. Linux targets are `linux-x64`, `linux-arm64`, `linux-riscv64` and
> `linux-arm` (armv7, selected by `@platforms//cpu:armv7`), reachable from every
> supported host. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
