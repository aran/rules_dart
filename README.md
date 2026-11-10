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

### Faster tests and builds (optional)

rules_dart's defaults work everywhere Bazel runs. These settings make builds
and tests faster where your setup allows them, and each asks something of you.
Put them in your `.bazelrc`.

**Start the test runner from a cached snapshot.** A `package:test` test's
start-up roughly halves (about 330 → 160 ms on macOS, 1050 → 400 ms on Linux).
The snapshot lives in a cache outside Bazel on each machine, trained by the
first test that needs it (see [Tests](#tests)).

```
test --@rules_dart//dart:runner_snapshot
```

Turn it on only where tests run on your own machines. The cache needs a
directory every test can write and that outlives a test: `/tmp` on macOS,
`/dev/shm` on Linux, local application data on Windows. A remote executor may
have none, which fails every test, or a fresh one for each action, which makes
every test train a snapshot it then throws away. If yours keeps a writable
`/dev/shm` between actions with room for the snapshots (about 50 MB for each
`package:test` version and Dart SDK), the cache works there too. Otherwise,
turn it on under a config only local runs use:

```
test:local --@rules_dart//dart:runner_snapshot
```

**Share actions between configurations (Linux, macOS, remote execution).** A
library built in two configurations (for the host and the target, or for a
platform transition) compiles twice. With path mapping, one result serves
both:

```
common --enable_platform_specific_config
common:linux --experimental_output_paths=strip
common:macos --experimental_output_paths=strip
```

Bazel runs a path-mapped action only in a sandbox or remotely, so leave it off
on Windows, where it fails the build. Rules of your own that pass a
configuration's output path to an action as a string, rather than a `File`,
must be fixed first (see [Architecture](docs/ARCHITECTURE.md)).

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

To write or re-resolve a `pubspec.lock` with the same SDK, run pub:

```shell
bazel run @rules_dart//dart/pub -- get
bazel run @rules_dart//dart/pub -- upgrade --directory=app path
```

It runs at the root of the workspace, so `--directory` is relative to that
root, and any pub subcommand works. It needs only the Dart toolchain, so it
runs while `pub.from_lock()` refuses a lock, which is when the errors that
refusal prints tell you to run it.

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

#### Where a package's root is

A package's root is the directory that holds its `lib/`. A `dart_library`
whose BUILD file is at the root, or in `lib/`, or in any directory under
`lib/`, belongs to the package rooted above that `lib`. One package can
therefore be split over several BUILD files, each `dart_library` holding the
files beside it:

```starlark
# greeter/lib/src/model/BUILD.bazel: package:greeter/src/model/model.dart
dart_library(
    name = "model",
    package_name = "greeter",
    srcs = ["model.dart"],
    deps = ["//greeter/lib/src/util"],
)
```

Each part depends on the parts its files import, relative imports included,
and a consumer depends on the parts it imports. Without `package_name`, a
package is named for its root directory. A directory named `lib` inside a
`lib/` (`lib/src/lib/`, or a package rooted under some other `lib/`) leaves the
root ambiguous and is an error; rename the inner directory.

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
given a filter, tags or shards, because it has no cases to select.

Cases within a target are selected by their `package:test` tags (`@Tags` on
the library, `tags:` on `group` and `test`); whole targets are selected by
Bazel's `tags` and `--test_tag_filters`, into which Gazelle copies a file's
`@Tags` (see [Test tags](#test-tags)). A
target's `include_tags` and `exclude_tags` are lists of boolean selectors, as
`dart test --tags`/`--exclude-tags` take them: a case runs when it matches
every `include_tags` entry and no `exclude_tags` entry, and a target none of
whose cases are left fails. One run narrows that further, without rebuilding,
with `--test_env=DART_TEST_TAGS=<selector>` and
`--test_env=DART_TEST_EXCLUDE_TAGS=<selector>`, whose values are written as
`dart test --tags` takes them (`a,b` is `a && b`). These combine with the
target's as `package:test` combines its configuration with its command line,
and with `--test_filter`. A run's selection that leaves a target no case
passes, saying on stderr which tags the target's cases use, so
`bazel test //... --test_env=DART_TEST_TAGS=integration` runs the cases tagged
`integration` wherever they are.

```starlark
dart_test(
    name = "parser_test",
    exclude_tags = ["slow"],
    main = "test/parser_test.dart",
    deps = [":parser", "@deps//:test"],
)
```

The runner reads no `dart_test.yaml`, neither the package's nor one at the
workspace root: each setting it holds has its place on the target or in
Bazel. Moving a package to Bazel moves them into its BUILD files:

- `include_tags`, `exclude_tags`: the attributes of the same names, and
  `DART_TEST_TAGS`/`DART_TEST_EXCLUDE_TAGS` for one run.
- `timeout`: the target's `size` or `timeout`. A `@Timeout` or `timeout:` in
  the test still applies to its own cases.
- `retry`: the target's `flaky`, or `--flaky_test_attempts`.
- `concurrency`, sharding: `shard_count`, and Bazel's own parallelism across
  targets.
- Its other keys have no counterpart: cases that need other settings go in a
  target of their own.

With no file to declare them in, the runner warns of every tag a test uses as
"not specified in dart_test.yaml"; the warning is harmless under Bazel.

With `--@rules_dart//dart:runner_snapshot` (see
[Faster tests and builds](#faster-tests-and-builds-optional)), the runner
starts from a snapshot of itself cached on the machine, which roughly halves a
test's start-up. The first test to find none trains it, once
per `package:test` runner and Dart SDK: after the test, it loads the test's
file again with no case selected, while the VM records the runner's compiled
code. The cache is outside Bazel, because a snapshot's bytes differ from one
training to the next, and it cannot change a test's result. It lives in
`/tmp/rules_dart-<uid>/runner` on macOS, `/dev/shm/rules_dart-<uid>/runner`
on Linux (both cleared at reboot) and `%LOCALAPPDATA%\rules_dart\runner` on Windows,
and keeps the eight snapshots used most recently. To put it elsewhere, pass
`--test_env=RULES_DART_RUNNER_SNAPSHOT_DIR=<dir> --sandbox_writable_path=<dir>`.
Anything that goes wrong with it fails the test, saying so.

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
outlines are made by a stripper built on the source of the same Dart SDK as
the compiler, which each Dart toolchain registers beside it. With a Dart SDK of
your own (a fork, a local build), register a `dart_outline_toolchain` built on
its `pkg/kernel`, or turn outlines off with
`--@rules_dart//dart:outline_kernel=false`, and dependents compile against full
kernels.

A test's program is a kernel list: a small text file naming the kernels it
reaches, its entrypoint's first, which the Dart VM loads as one program. Each
kernel is stored once however many tests reach it, rather than copied into
every test. The launcher writes the list again at each run, naming each kernel
where it finds it in runfiles, so the test runs the same under `bazel test`,
`bazel run`, a runfiles manifest (Windows) and remote execution. To store one
joined kernel per test instead, as before:
`--@rules_dart//dart:kernel_list=false`.

A rule set whose tests link through `dart_link_kernel_action` reads, joins or
rewrites these lists in its launcher with the `@rules_dart//dart/kernel_list`
library (`package:kernel_list/kernel_list.dart`): `kernelsInRunfiles` finds a
program's kernels through runfiles, `writeKernelList` writes a list naming
them, and `joinKernels` joins them for a program that takes a single kernel
file, in memory on Linux and in a temporary file elsewhere.

A test's `defines` are configuration: its dependencies' modules are compiled in
the same environment as its entrypoint. A rule set's executable gets that
environment from `executable_defines_config` in `@rules_dart//dart:utils.bzl`,
which also takes the declarations the rule derives from its other attributes:

```starlark
def _flavor_defines(attr):
    return ["APP_FLAVOR=" + attr.flavor] if attr.flavor else []

_ENVIRONMENT = executable_defines_config(_flavor_defines)

my_test = rule(
    attrs = _ENVIRONMENT.attrs | {
        "deps": attr.label_list(aspects = [my_module_aspect], cfg = _ENVIRONMENT.cfg),
        "defines": attr.string_list(),
        "flavor": attr.string(),
        "_extra_dart_defines": attr.label(default = "@rules_dart//dart:extra_dart_defines"),
        # ...
    },
    # ...
)
```

The environment is `defines`, then the derived declarations, then the
`extra_dart_defines` flag. `dart_entry_kernel_action` compiles the entrypoint in
it and fails if a dependency's modules were compiled in another; a compile the
rule runs itself, such as one of the whole program, takes
`executable_defines(ctx)`. A derived key that `defines` also sets is an error.

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
than 2.19 has none and is refused, so re-resolve it
(`bazel run @rules_dart//dart/pub -- get --directory=<its directory>`). Every
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
> every ref it advertises instead, as pub does. Packages with `sdk` sources
> (e.g. Flutter's) are skipped: they come from the SDK itself, not pub, and no
> repository is created for them, so `package:` imports of those packages fail
> to resolve unless they are provided another way. Each `from_lock()` prints
> one summary of everything it skipped, grouped by source. A fetched package
> that depends on a skipped one fails when it is fetched, naming the
> dependency, rather than building without it.

`resolve` serves a locked package from a target of yours instead of what the
lock describes. Every `path` package in the lock must be named in exactly one
of `resolve`, `build_from_pubspec` or `ignored` (below); a hosted, git or sdk
package may be mapped too, to build a fork, say:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    resolve = {
        "my_shared_models": "//shared_models",  # a `path` package: must be mapped
        "http": "//third_party/http_fork",      # a hosted package: replaced
    },
)
```

A mapped package is that target for the whole build: `@pub_deps//:http`
aliases it, and every locked package that depends on `http` depends on it. The
target must build the package of that name (its `dart_library`'s
`package_name`), which is checked when it is analyzed, and must be visible to
the extension's repositories (`//visibility:public`). The lock's version is not
checked. A `path` package left unmapped, or a mapped name the lock does not
list, fails when the lock is read, naming each; two `from_lock()` calls that map
a package to different targets fail too, as does mapping a package also
declared with `pub.package()`. Gazelle resolves `package:http`
imports to `@pub_deps//:http`, which now leads to the mapped target, so it
needs no `# gazelle:resolve` for that package.

A `path` package with no Bazel build of its own is built from its directory
with `build_from_pubspec`, the way a hosted package is built from its archive:
the lock's path, resolved against the lock's directory, holds it, and its
`pubspec.yaml`, `lib/`, `hook/` and license file are served from there (other
files, such as `.dart_tool/` and `build/`, are not, so pub and IDE output
changes nothing). An edit under those reaches the next build. A package with a
`BUILD` file anywhere under them is refused: map it with `resolve`. A `path`
package nothing in the build uses, such as one only an editor or a pub-side
tool reads, is named in `ignored` with the reason; its hub label exists, and
anything that depends on it fails at analysis with that reason:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    build_from_pubspec = ["local_greeting"],
    ignored = {"editor_only": "only the editor reads it"},
)
```

The lock must name the directory by a relative path, as `dart pub get` writes
it for a relative `path:` in the pubspec, and it must be inside the repository
that holds the lock: an absolute path, or one leading out of the repository,
holds only on one machine and fails when the lock is read. Map such a package
with `resolve` instead.

Two locks building one package must name the same directory, and a package
built from its pubspec in one lock and fetched or ignored in another fails,
naming both.

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
its lock. Between locks, the highest version a lock records is built, and a
lock that records a lower one fails the build unless its `from_lock()` sets
`on_version_conflict = "upgrade"`; the error gives the
`bazel run @rules_dart//dart/pub -- upgrade` command that brings it forward.

A dependency's `pub.package()` version is a minimum, as a dependency's Dart SDK
request is: the root wins only at the same or a newer version, and a newer one prints a
warning naming the module it raised, as Bazel does for a `bazel_dep`. A root `pub.package()` or lock
older than one a dependency declared fails the build, naming the package, both
versions and the module; raise the root's version, or hold the older one on
purpose with `pub.settings(allow_older_than_dependencies = True)` in the root
module.

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
`dart_library`, `dart_binary`, and `dart_test` targets respectively; for a
package in a subdirectory, the ones beside its `pubspec.yaml`. It
resolves `import` statements to determine `deps`, including support for
`show` and `deferred` import modifiers.

Each directory under `lib/` gets its own `dart_library`, named for the
directory, in the package rooted above `lib/` (see
[Where a package's root is](#where-a-packages-root-is)). An imported file,
by `package:` URI or relative path, resolves to the rule that lists it; only
an import of a file no generated or hand-written rule lists by name (a pub
package's, or one in a `glob`) resolves by package name. A file two rules list
is logged rather than guessed; a `# gazelle:resolve dart package:<pkg>/<path>
<label>` directive picks one.

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

#### Test tags

A test file's suite-level package:test tags become its `dart_test`'s Bazel
`tags`:

```dart
@Tags(['slow', 'integration'])
library;

import 'package:test/test.dart';
```

```starlark
dart_test(
    name = "checkout_test",
    main = "checkout_test.dart",
    tags = [
        "integration",
        "slow",
    ],
    ...
)
```

so Bazel's own tag filters select whole test files:

```shell
bazel test //... --test_tag_filters=-slow          # skip slow files
bazel test //... --test_tag_filters=integration    # only integration files
```

Gazelle reads `@Tags` where package:test does, on the file's first directive
(`library`, `import`, `export` or `part`), bare or import-prefixed
(`@t.Tags([...])`). Tags on individual tests and groups (`test(..., tags: ...)`)
stay with package:test. Gazelle warns instead of copying when the annotation is
not a list of string literals (a `const` variable, say), and for a tag Bazel
gives meaning to (`manual`, `exclusive`, `external`, `local`, and the `no-*`,
`requires-*`, `supports-*`, `disable-*` and `block-network` execution tags),
since copying it would change how the test runs.

Gazelle manages `tags` on `dart_test`: a tag removed from `@Tags` leaves the
target on the next run. A tag you write yourself stays only when marked
`# keep`, as for every attribute Gazelle manages, and Gazelle logs each tag it
removes:

```starlark
    tags = [
        "exclusive",  # keep
        "slow",
    ],
```

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

## Flags

Every command-line setting rules_dart reads. Set one per invocation or in
`.bazelrc` (`common --@rules_dart//dart:<name>=<value>`).

| Flag                                               | Default | What it does                                                                                                                                                  |
| -------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--@rules_dart//dart:analysis_config=<label>`      | none    | The `dart_analysis_config` whose options analysis, fixes and formatting use.                                                                                  |
| `--@rules_dart//dart:analysis_worker`              | on      | Runs analysis and fixes in persistent workers, one analysis server each; off runs `dart analyze`/`dart fix` per action.                                       |
| `--@rules_dart//dart:extra_dart_defines=KEY=VALUE` | none    | Adds an environment declaration to every Dart compile, after target `defines`; repeat for more.                                                               |
| `--@rules_dart//dart:kernel_list`                  | on      | Runs each test from a kernel list naming the kernels it reaches; off stores one joined kernel per test.                                                       |
| `--@rules_dart//dart:modular_kernel`               | on      | Compiles each library once into kernel modules that tests link; off compiles each test's whole program from source and stops checking imports against `deps`. |
| `--@rules_dart//dart:outline_kernel`               | on      | Compiles dependents against outlines of their dependencies' modules, made by the outline toolchain of the Dart SDK; off compiles them against full kernels.   |
| `--@rules_dart//dart:runner_snapshot`              | off     | Starts the `package:test` runner from a snapshot cached on the machine (see [Tests](#tests)); off starts it from its kernel and touches no cache.             |
| `--@rules_dart//dart:track_creation_locations`     | off     | Compiles VM kernels with `--track-creation-locations` (`--track-widget-creation`).                                                                            |

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example                                                     | What it demonstrates                                                                     |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [`hello_world`](e2e/hello_world/)                           | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`, `jit-snapshot`)     |
| [`library_deps`](e2e/library_deps/)                         | Transitive `dart_library` dependencies, `srcs` attribute                                 |
| [`dart_test`](e2e/dart_test/)                               | Tests with and without deps, `srcs` for test helpers                                     |
| [`analysis`](e2e/analysis/)                                 | The `dart_analyze` aspect's checks with `package:`-included options                      |
| [`fix`](e2e/fix/)                                           | `dart_fix` write-back, and that generated files are never rewritten                      |
| [`analyze_composition`](e2e/analyze_composition/)           | A lint ruleset shared from another Bazel module                                          |
| [`web_app`](e2e/web_app/)                                   | JavaScript and WebAssembly compilation with library deps                                 |
| [`web_compiler`](e2e/web_compiler/)                         | Per-compiler code by `select()`, and the resets other modules' rules use                 |
| [`pub_deps`](e2e/pub_deps/)                                 | Single pub.dev package via `pub.package()`                                               |
| [`pub_lock`](e2e/pub_lock/)                                 | Multiple packages from `pubspec.lock` via `pub.from_lock()`                              |
| [`gazelle`](e2e/gazelle/)                                   | Automatic BUILD file generation with Gazelle                                             |
| [`cross_compile`](e2e/cross_compile/)                       | Cross-compilation to other platforms via `platform_data` transition                      |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                       | `dart_test` with pub dependencies via `pub.from_lock()`                                  |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)                     | Cross-lock-file package deduplication                                                    |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)                 | Version conflict resolution with `on_version_conflict = "upgrade"`                       |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)               | Version conflict detection across lock files                                             |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/)       | `pub.from_lock()` across Bazel module boundaries                                         |
| [`pub_lock_cycle`](e2e/pub_lock_cycle/)                     | Packages that depend on each other (`dio`, `dio_web_adapter`), on the VM and the web     |
| [`pub_member_kind`](e2e/pub_member_kind/)                   | Another rule set's own pub package kind, in a cycle, over the public pub surface         |
| [`toolchain_pin_conflict`](e2e/toolchain_pin_conflict/)     | A root `dart.toolchain` pin below a dependency's request fails, naming the dependency    |
| [`pub_lock_unsupplied`](e2e/pub_lock_unsupplied/)           | A hosted package depending on an unsupplied sdk package fails, naming it                 |
| [`pub_lock_resolve`](e2e/pub_lock_resolve/)                 | `resolve` serving a `path` package and replacing a hosted one for the whole graph        |
| [`pub_lock_resolve_invalid`](e2e/pub_lock_resolve_invalid/) | Unnamed, twice-named and wrongly named `path` packages and a stale `resolve` key fail    |
| [`pub_lock_path`](e2e/pub_lock_path/)                       | `path` packages built from their pubspec, ignored, or refused for having a BUILD file    |
| [`pub_hub_surface`](e2e/pub_hub_surface/)                   | Every locked package in its hub, including one declared with `pub.package()`             |
| [`pub_override_root_lock`](e2e/pub_override_root_lock/)     | The root's lock wins over a dependency module's `pub.package()`                          |
| [`pub_package_conflict`](e2e/pub_package_conflict/)         | Two dependency modules' differing `pub.package()`s fail, naming both                     |
| [`pub_root_older_package`](e2e/pub_root_older_package/)     | A root `pub.package()` below a dependency's fails, naming both versions                  |
| [`pub_root_older_lock`](e2e/pub_root_older_lock/)           | A root lock below a dependency's `pub.package()` fails, naming both versions             |
| [`pub_root_older_allowed`](e2e/pub_root_older_allowed/)     | `pub.settings(allow_older_than_dependencies = True)` lets the root hold the older one    |
| [`pub_root_newer`](e2e/pub_root_newer/)                     | A root lock above a dependency's `pub.package()` wins, warning that it raised it         |
| [`codegen`](e2e/codegen/)                                   | `dart_codegen`/`dart_aggregate_codegen` over parts, re-exports and source sets           |
| [`ext_exemplar`](e2e/ext_exemplar/)                         | One package per bundled `dart/ext` builder, plus native `code_assets`, sqlite3/webcrypto |
| [`dual_build`](e2e/dual_build/)                             | Collision detection between Bazel-generated and `build_runner`-generated sources         |
| [`link_hook`](e2e/link_hook/)                               | `record_use` and a package's `hook/link.dart` emitting a data asset via `dart_link_hook` |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` and `jit-snapshot` are VM formats that ignore target
> flags. Built natively, a `kernel`, `jit-snapshot` or `aot-snapshot` target's
> executable is a launcher that runs the output in the SDK's VM, so it works with
> `bazel run` and as `data`; cross-compiled, the target's executable is the
> output itself, for the target's own runtime to run. Linux targets are `linux-x64`, `linux-arm64`, `linux-riscv64` and
> `linux-arm` (armv7, selected by `@platforms//cpu:armv7`), reachable from every
> supported host. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
