# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

rules_dart is hermetic. Bazel downloads the Dart SDK the toolchain pins and runs
every tool from it, so a build means the same on every machine. A system-wide
Dart installation is not supported, and neither is a system-wide install of any
other Dart-ecosystem tool (`pub`, `build_runner`, `dart_style`). A `dart` on
your `PATH` plays no part: build, test, analyze, format and fix with the rules,
and run the SDK with `bazel run @rules_dart//dart -- ...` and pub with
`bazel run @rules_dart//dart/pub -- ...` (see
[Running the Dart SDK](#running-the-dart-sdk)).

## Road to 1.0

This project is getting dangerously close to being good. It's still a beta, but
we're approaching parity with the native tools, getting good performance, and
successfully using it to build Flutter apps across several platforms. There have
been several PRs and forks. Of course, the process of using AI to build software
like this is more like sculpting than careful assembly. Here, the form is taking
shape. In the latest round of changes, we made as many breaking changes as we
could, in the hopes of reducing how many breaking changes will need to be made
going forward. I'm still not committed to avoiding breaking changes, but I think
it's fair to discuss what it'll take to ship a 1.0 where there will be an
expectation that APIs will remain stable for quite some time.

As context, there are varying degrees of success possible for this project, and
I don't know where it will land. One possibility is that it remains small, used
by myself and a couple of others for small-scale, largely non-professional
projects. In this world, I'll label it 1.0 as a retroactive, descriptive
process. That is, when a few months go by where development has been happening
but the APIs have remained stable, we'll assume that they can probably be kept
stable for some time going forward, and we'll label it 1.0. This is probably the
most likely outcome.

Somewhere else in the range of possibilities, this project could get picked up
for professional use by others. It could even attract attention, and we could
end up with actual collaboration with teams within Google and others in the
Flutter and Bazel ecosystem. In an optimistic case, two or three profitable
companies start using it in production, and Google is potentially even tacitly
supportive of it, or at least not hostile to it. In this scenario, the road to
1.0 will be a little more formal and aligned with the interests and
contributions of those companies. In that scenario, we'll probably see a formal,
published release cycle, likely tied closely to Dart, Flutter and Bazel release
cycles. 1.0 will be tagged with a consensus of the early production users.

Now, of course, everything can change quickly in this world. Google could change
the way it supports Flutter or Bazel. Dart 4 is on its way and may engender
changes to projects like these. Everyone's expectations should be set
accordingly. I welcome discussions of this direction by email or in
[GitHub issues](https://github.com/aran/rules_dart/issues), and of course, if
you are using or considering using this project professionally, please contact
me so we can collaborate.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "<the latest release>")  # https://github.com/aran/rules_dart/releases
bazel_dep(name = "rules_dart_gazelle_plugin", version = "<the same version>")  # optional, see Gazelle

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.7")
use_repo(dart, "dart_toolchains")

register_toolchains("@dart_toolchains//:all")
```

The version is the newest release in the
[Bazel Central Registry](https://registry.bazel.build/modules/rules_dart). Each
[GitHub release](https://github.com/aran/rules_dart/releases)'s notes open with
the exact `bazel_dep` lines for both modules. `rules_dart_gazelle_plugin` is
released with rules_dart, from the same tag, so both take the same version; it
is a module of its own so that rules_dart brings no Go dependency, and a
workspace that does not generate its BUILD files with
[Gazelle](#build-file-generation-with-gazelle) leaves it out.

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

The toolchain downloads the SDK, and that SDK is the only one rules_dart uses:
install no Dart, and run no `dart` from a `PATH`. To run the `dart` CLI of the
pinned SDK:

```shell
bazel run @rules_dart//dart -- --version
```

It runs in the directory `bazel run` was invoked from, and, like every build
action, with Dart's analytics off, so it writes nothing into your home
directory.

Use it for commands that need no package resolution. It is not the way to
analyze, format or test: the packages Bazel builds have no
`.dart_tool/package_config.json`, and the files code generation writes exist
only under `bazel-bin`, so `dart analyze` reports their imports and generated
members as unresolved, errors the build does not have. Those jobs have Bazel
commands, which the [command map](#command-map) lists.

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
> to put the Bazel-managed binaries, the pinned `dart` among them, on your `PATH`
> for IDE and shell use.

### Command map

Dart's own guidance, and the tools and coding agents that follow it, name
commands that assume a system-wide Dart installation and a pub-resolved package
on disk. rules_dart supports neither (see [Running the Dart SDK](#running-the-dart-sdk)):
do not run `dart`, `pub`, `build_runner` or any other Dart tool from a system
install. Bazel builds each package and runs the pinned SDK, so each command in
the left column has a Bazel counterpart or none. The Dart SDK and pub are run
as `bazel run @rules_dart//dart -- ...` and `bazel run @rules_dart//dart/pub -- ...`;
everything else is a rule. `<dir>` is a package's directory relative to the
workspace root.

| Dart command | In a rules_dart workspace |
| --- | --- |
| `dart pub add foo`, `remove`, `get`, `upgrade`, `outdated`, `deps` | `bazel run @rules_dart//dart/pub -- add foo --directory=<dir>` (any pub subcommand), which runs the pinned SDK at the workspace root. The build reads `pubspec.lock` alone, so a `pubspec.yaml` edit changes nothing until pub re-resolves. After `add`, run Gazelle. See [Adding a dependency](#adding-a-dependency). |
| `dart analyze` (`--fatal-infos`) | `bazel test //<dir>/...`, with the `dart_analyze` aspect lines in `.bazelrc`. Every diagnostic, infos included, fails the test. `bazel build` does not analyze. See [Static analysis and formatting](#static-analysis-and-formatting). |
| `dart format` | The check is part of the same `bazel test` (the `dart_format` output group). To rewrite files: `bazel run @rules_dart//dart/format -- //<dir>/...`, which takes `bazel build`'s flags and target patterns. |
| `dart fix --dry-run` / `--apply` | `bazel run @rules_dart//dart/fix -- --dry-run //<dir>/...` / `bazel run @rules_dart//dart/fix -- //<dir>/...`. See [Formatting and fixing](#formatting-and-fixing). |
| `dart test` | `bazel test //<dir>:<name>`, or `//<dir>/...`. See below for its flags. |
| `dart run build_runner build` / `watch` | None: do not run `build_runner`. The build generates the code, and the outputs are under `bazel-bin`, at the source file's path. See [Code generation](#code-generation). |
| `dart run bin/app.dart` | `bazel run //<dir>:app`, a `dart_binary`. |
| `dart compile exe` / `aot-snapshot` / `kernel` | `dart_binary(compile_mode = ...)`, default `exe`. |
| `dart compile js` / `wasm` | `dart_js_binary` / `dart_wasm_binary`. See [Web compilation](#web-compilation). |
| `dart doc` | None. |
| `dart run coverage:test_with_coverage`, `dart test --coverage` | `bazel coverage --combined_report=lcov //<dir>/...`, which writes one LCOV report for every test it runs. See [Coverage](#coverage). |

`dart test`'s options map as follows.

| `dart test` | `bazel test` |
| --- | --- |
| `--name`, `-n` | `--test_filter=<regex>`, which the runner passes on as `--name`, so it is a regular expression. It selects within the targets named, so `bazel test //<dir>:<name> --test_filter=...` runs one case. |
| `--plain-name`, `-N` | None; escape the regex metacharacters in `--test_filter`. |
| `--tags`, `-t`, `--exclude-tags`, `-x` | The target's `include_tags` / `exclude_tags`, or `--test_env=DART_TEST_TAGS=<selector>` / `DART_TEST_EXCLUDE_TAGS` for one run. A file's `@Tags` also select whole targets through `--test_tag_filters`. See [Tests](#tests). |
| `--shard-index`, `--total-shards` | `shard_count`. |
| `--timeout` | The target's `size` or `timeout`. |
| `--concurrency`, `-j` | Bazel runs targets in parallel (`--local_test_jobs`); a target's cases run in one runner. |
| `--reporter`, `--file-reporter`, other runner flags | No pass-through. Cases appear in Bazel's report (`test.xml`); `--test_output=errors` or `all` shows the runner's output. |

`dart_test.yaml` is not read, neither a package's nor the workspace's: each
setting has its place on the target or in Bazel (see [Tests](#tests)). The
runner's warning that a tag is "not specified in dart_test.yaml" is harmless;
creating the file does not silence it and changes nothing. `build.yaml` is not
read either: a builder's options go in its macro's `config` (or
`# gazelle:dart_builder_config`), and the macro's `srcs` choose the files it
runs on (see [`docs/ext.md`](./docs/ext.md)). Gazelle writes a builder's
`options` from `build.yaml` into `config` for you, and fails on the rest of the
file (see [build.yaml](#buildyaml)).

Tools that follow Dart's guidance directly, an editor's analysis server and
`dart mcp-server`'s `analyze_files` and `run_tests` among them, read
`.dart_tool/package_config.json`, which only `pub get` writes and which knows
nothing of the packages Bazel builds or of generated files in `bazel-bin`. They
report unresolved imports and undefined generated members that `bazel test`
does not. Do not add those packages to `pubspec.yaml`, or hand-write the
generated files, to quiet them: run `bazel test`, which is the analyzer here.

### Working with coding agents

A coding agent knows Dart from documentation that assumes a system `dart`, a
pub-resolved package and `build_runner`. Tell it what is true here in the
repository's `AGENTS.md` (or `CLAUDE.md`), adjusting the target names (`//:gazelle`,
`//:format`, `//:fix`) to yours:

```markdown
- This workspace is built by Bazel with a hermetic Dart SDK. Never run `dart`,
  `pub` or `build_runner` from a system install. Run the pinned SDK as
  `bazel run @rules_dart//dart -- <args>` and pub as
  `bazel run @rules_dart//dart/pub -- <args> --directory=<dir>`.
- `bazel test //<dir>/...` is the analyzer and the format check: it fails on
  every diagnostic, infos included, and on a file `dart format` would change.
  `bazel build` checks neither. Run it before finishing. `bazel run //:fix` applies
  the analyzer's fixes and `bazel run //:format -- <paths>` formats.
- Never run `build_runner`, and never write or commit generated code. The build
  generates it; the outputs are under `bazel-bin`, at the source file's path.
- After adding, removing or renaming a Dart file or an import, run
  `bazel run //:gazelle`, which rewrites `BUILD.bazel` files. After
  `bazel run @rules_dart//dart/pub -- add <package> --directory=<dir>`, run it
  again, so that `package:<package>` imports get their `deps`.
- The build reads neither `build.yaml` nor `dart_test.yaml`. Gazelle carries
  a builder's `build.yaml` options into its codegen target's `config`; a
  test's tags, timeout, retries and shards go on the `dart_test` target.
- Unresolved imports or missing generated members reported by an editor or
  `dart mcp-server` are not errors in the build. Do not edit `pubspec.yaml`
  to quiet them.
```

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

#### A package's facts, and where its root is

A package's root is the directory that holds its `lib/`. A `dart_library`
whose BUILD file is at the root, or in `lib/`, or in any directory under
`lib/`, belongs to the package rooted above that `lib`. One package can
therefore be split over several BUILD files, each `dart_library` holding the
files beside it.

What `pubspec.yaml` says about a package (its name, its language version, its
hooks, its license) is stated once, on a `dart_package_metadata`, and every
target of the package names it with `package`. Its name is yours to choose. It
declares the package rooted at its BUILD file's directory, or, in a BUILD file
under `lib/`, at the directory above that `lib`. A package has one, as it has
one `pubspec.yaml`: a program, test, library or analysis that reaches targets
naming two declarations for one root fails, naming both.

```starlark
# greeter/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "greeter",
    language_version = "3.11",
    license_file = "LICENSE",
    visibility = [":__subpackages__"],
)

dart_library(
    name = "greeter",
    srcs = ["lib/greeter.dart"],
    package = ":pubspec-metadata",
    deps = ["//greeter/lib/src/model"],
)

# greeter/lib/src/model/BUILD.bazel: package:greeter/src/model/model.dart
dart_library(
    name = "model",
    srcs = ["model.dart"],
    package = "//greeter:pubspec-metadata",
)
```

Each part depends on the parts its files import, relative imports included,
and a consumer depends on the parts it imports. Every record of the package
then carries every fact, whichever of its targets a program reaches; two
targets of one package naming different `dart_package_metadata`, or one naming
it and one not, fail the build, naming both. A package with no
`dart_package_metadata` is named for its root directory and states nothing
else: its sources compile at the SDK's own language version. A directory named
`lib` inside a `lib/` (`lib/src/lib/`, or a package rooted under some other
`lib/`) leaves the root ambiguous and is an error; rename the inner directory.
Gazelle writes the `dart_package_metadata` from `pubspec.yaml` (see
[Gazelle](#gazelle)).

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
your own (a fork, a local build), register a `dart_outline_toolchain` whose tool
is the `:outline_tool` of a `dart_kernel_source(path = "<checkout>")`, built
on the `pkg/kernel` of that SDK's source checkout (`third_party/dart` in a
Flutter engine checkout). A repository rule that already reads the checkout
calls `fetch_dart_kernel_source(rctx, path, prefix)` (`@rules_dart//dart:repositories.bzl`)
to put the same packages and stripper in a directory of its own repository.
Or turn outlines off with `--@rules_dart//dart:outline_kernel=false`, and
dependents compile against full kernels.

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

#### Coverage

`bazel coverage` runs `dart_test` targets and collects the lines they run,
with nothing to install: the hermetic Dart VM counts what runs, and the
collector is built from rules_dart's pinned `package:coverage`.

```sh
bazel coverage --combined_report=lcov //...
```

Bazel prints where the merged LCOV report is
(`$(bazel info output_path)/_coverage/_coverage_report.dat`); each test's own
is `bazel-testlogs/<package>/<name>/coverage.dat`. Any LCOV tool reads them.

- **What is reported.** The `srcs` of every `dart_library` a test reaches
  through `deps`, for the libraries `--instrumentation_filter` selects (by
  default those in the packages named on the command line), each file under
  its path in the workspace; a generated file is under its `bazel-out/` path.
  A test's own `main` and `srcs` are reported only with
  `--instrument_test_targets`, as for every Bazel language. Lines only: no
  function or branch counts. A line marked `// coverage:ignore-line`, the
  lines from a `// coverage:ignore-start` to the next `// coverage:ignore-end`,
  and a file with a `// coverage:ignore-file` are left out, as `dart test
  --coverage-path` leaves them out; an unbalanced marker fails the test.
- **Plain-`main()` tests** run with the VM service on, each isolate pausing as
  it exits until its coverage is read. Such a test must return from `main`
  (setting `exitCode` to fail): `exit()` ends the VM before it pauses, and
  under `bazel coverage` the test then fails, saying so.
- **`package:test` tests** have their runner collect each suite.
- **The build is the same.** The VM counts lines in any kernel, so a coverage
  build compiles the kernels a test build does; only the test's launcher
  configuration and runfiles differ, the latter carrying the reported sources,
  which the ignore comments are read from.
- Bazel's own report merger needs a runfiles tree, so `bazel coverage` fails
  with `--noenable_runfiles`, Windows' default.

**For rule authors.** A test rule that collects coverage from a Dart VM of its
own (a Flutter test's) reuses the conversion: it merges
`COVERAGE_ATTRS` from `@rules_dart//dart:utils.bzl` into its `attrs` (the
converter and the `_lcov_merger` Bazel's coverage runner needs), gives its
result `coverage_common.instrumented_files_info`, and calls
`test_coverage(ctx, packages, sources, deps)` with the test's own Dart files
and its `deps`, which is `None` unless the build is for coverage and otherwise
writes the file naming the packages' `lib/` directories and the runfiles path of
each source Bazel instruments, and returns `converter` and `sources` (runfiles
paths) and the `runfiles` to merge into the test's, which carry those sources. Inside the test, over a directory of `package:coverage`
JSON (what its `collect` returns, one file per suite), it runs
`@rules_dart//dart:coverage_converter`:

```sh
coverage_converter --hitmaps=<dir> --sources=<sources> --output=$COVERAGE_DIR/<name>.dat
```

`--hitmaps` is searched for `*.json` at any depth, and the counts of a script
in several files add. `--output` ends in `.dat`, in `COVERAGE_DIR`. Bazel's
`COVERAGE_MANIFEST` must be set, as must the test's runfiles variables, which a
process the test starts inherits; a script the manifest does not list is not
reported. The exit status is 0, 2 for a usage error, or another value for a
failure, with a message on stderr. These flags are stable.

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

A package is built with the dependencies its own pubspec states. Each must be
supplied in the build, by another `pub.package()` or a `pub.from_lock()` lock;
one that is not fails when the package is fetched, naming both.

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
target must build the package of that name (the `package_name` of its
`dart_package_metadata`), which is checked when it is analyzed, and must be visible to
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

#### Packages that depend on each other

Pub allows packages to depend on each other in a cycle (`dio` and
`dio_web_adapter` import each other); Bazel does not. Such packages are built
as one library, each keeping its own name and language version, so
`@pub_deps//:dio` and `@pub_deps//:dio_web_adapter` both name it. A cycle is
built that way only where it is declared, whether its packages come from a lock
or from `pub.package()`:

```starlark
pub.cycle(packages = ["ping", "pong"])
```

An undeclared cycle fails when something first builds one of its packages,
naming every package in it and the `pub.cycle()` to add. A declaration must
name exactly one cycle at the versions the build fetches: one naming packages
that are no cycle (a new release dropped the edge, say) or only part of one
fails the same way, so a declaration cannot outlive its cycle.

Cycles are build-wide, as versions are, and the root module decides. Its
declarations are checked as above. Those of a module the root depends on apply
where they name exactly a cycle and are otherwise inert, since that module
cannot fix what the root's versions made of them, and the root can. rules_dart
declares the cycles of well-known packages itself, so a build using them needs
no declaration; those apply the same way, and are inert where the packages are
not that cycle. Two declarations naming the same packages agree; declarations
that share only some packages cannot both name exactly a cycle, and the root's
is checked, so at most one applies. The curated cycles are listed by
`curated_cycles()` in
[`dart/ext/registry.bzl`](dart/ext/registry.bzl); today they are:

| Packages                 | Why                                                           |
| ------------------------ | ------------------------------------------------------------- |
| `dio`, `dio_web_adapter` | `dio` exports the web adapter on the web, which imports `dio` |

rules_dart builds one version of each package for the whole build. Every
statement of a hosted package's version is a request: a `pub.package()` in any
module, and every lock that lists it. The highest request is built, as Bazel's
minimal version selection picks the highest version any module asks for, and a
`pub.package()` whose request loses keeps its `@name` repository, naming the
version built. Two requests of one version must pin one sha256.

A request is a minimum, so when a module the root depends on asks for more than
the root does, the build takes it, and reports that the root's request was
raised, as Bazel's `--check_direct_dependencies` does for a `bazel_dep`:

```text
Package "tuple" is built at 2.0.2, newer than the root module asks for:
  - 2.0.1, from the lock `//:pubspec.lock`
Raised by:
  - 2.0.2, from `pub.package()` in module `dep_mod`
Each request is a minimum and the highest wins. Raise the root's to 2.0.2:
  bazel run @rules_dart//dart/pub -- upgrade tuple
or set `pub.settings(check_direct_dependencies = "off")` in the root module to stop this check.
```

The root module sets how this is reported, once:

```starlark
pub.settings(check_direct_dependencies = "error")  # "off", "warning" (the default) or "error"
```

Only the root's own requests are checked: raising a dependency's request, by
the root or by another dependency, says nothing, as in Bazel. A package the
root's lock lists as `git`, `sdk` or `path` is what that lock says for the whole
build, over another module's `pub.package()` or lock entry for it, as a root
`git_override` is over a `bazel_dep`, since there is no version order to
compare. Only the root module may use `pub.settings`, `ignore_hooks` or
`ignore_hook`.

The Dart SDK is not a request: the root's `dart.toolchain` pin is exact, and a
module asking for a newer SDK fails the build, naming the fix.

#### Adding a dependency

pub resolves and records versions; Bazel builds exactly what `pubspec.lock`
records. Adding a package takes three steps:

```shell
bazel run @rules_dart//dart/pub -- add foo --directory=app   # edits app/pubspec.yaml and app/pubspec.lock
bazel run //:gazelle                                          # puts @pub_deps//:foo in the deps that import it
bazel build //app/...
```

1. `pub add` runs the toolchain's pinned SDK at the workspace root, so
   `--directory` names the package holding the `pubspec.yaml`, and takes pub's
   usual forms (`add dev:foo`, `add foo:^1.2.0`, `remove foo`). It must be the
   directory whose `pubspec.lock` the `pub.from_lock()` names. To change a
   constraint by hand, edit `pubspec.yaml` and run `pub get` (or
   `pub upgrade foo`): the build reads only the lock, so an edit pub has not
   resolved changes nothing.
2. Import the package in the source, then run Gazelle, which resolves
   `package:foo/...` to `@pub_deps//:foo` (the repository named by
   `# gazelle:dart_pub_deps_repo`). Without Gazelle, add `@pub_deps//:foo` to
   the `deps` of the targets that import it.
3. Build. An error that `@pub_deps//:foo` does not exist means the lock does
   not list `foo`: step 1 has not run for that lock.

`use_repo(pub, "pub_deps")` does not change: the hub holds every package the
lock names. A workspace with no `pubspec.yaml`, only `pub.package()`
declarations, has nothing for `pub add` to edit; add the declaration by hand,
with the digest below.

#### The sha256 of a `pub.package()`

`pub.package()` needs the digest of the package's archive, which Bazel checks
on download: 64 lowercase hex digits, as `pubspec.lock` records it. Take it
from pub.dev's API, where it is `archive_sha256`:

```shell
curl -s https://pub.dev/api/packages/path/versions/1.9.1 | jq -r .archive_sha256
```

or, for a package that is in a `pubspec.lock` already, from the `sha256:`
under its `description`. A digest of any other shape fails when
`pub.package()` is read, naming the package.

### BUILD file generation with Gazelle

rules_dart's [Gazelle](https://github.com/bazelbuild/bazel-gazelle) plugin
generates `BUILD.bazel` files from your Dart source tree. It is a module of its
own, `rules_dart_gazelle_plugin`, released with rules_dart at the same version,
so that rules_dart itself brings no Go dependency.

Add it and `gazelle` to your `MODULE.bazel`:

```starlark
bazel_dep(name = "gazelle", version = "0.54.0")
bazel_dep(name = "rules_dart_gazelle_plugin", version = "<the rules_dart version>")
```

Then create a root `BUILD.bazel` with the Gazelle targets:

```starlark
load("@gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = [
        "@rules_dart_gazelle_plugin//dart",
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
`dart_library`, `dart_binary`, and `dart_test` targets respectively. As
upstream, a Dart file belongs to the innermost package whose root holds it,
and a package's root is the directory holding its `pubspec.yaml`, or else a
`dart_package_metadata`: every directory below it, `tool/`, `example/` and
`benchmark/` too, is in that package, and each rule Gazelle writes there names
its metadata, up to an `example/` (or any directory) with a pubspec of its
own, which is a package of its own. A package with neither has its root above
its `lib/`, `bin/` and `test/`, as `dart_library` derives it. Gazelle
resolves `import` statements to determine `deps`, including support for
`show` and `deferred` import modifiers.

Dart files in any other directory (`tool/`, `example/`) are scripts, as
`dart run tool/x.dart` runs them: each file with a top-level `main` is a
`dart_binary`, holding in `srcs` the files beside it that it imports, directly
or through one another. A file there with no `main` that no script beside it
imports fails the run, naming it.

As package:test does, Gazelle makes a test of each `_test.dart` file. Any other
file in `test/` is a helper: it goes in the `srcs` of every test that imports
it, directly or through another helper, and what it imports in that test's
`deps`. A helper in the test's own directory is listed by name. A directory
under `test/` that a file elsewhere imports from gets a `filegroup` named for
it, holding its helpers (and any test imported from elsewhere), visible to the
package's `test/` tree, and the test lists that instead.

A package is one `dart_library`, in the BUILD file at the package's root
(see above), named for the
package and holding every file under its `lib/`, as `pub.from_lock()` builds a
pub package. Directories under `lib/` mean nothing to Dart, and import cycles
between them are ordinary Dart, so they need nothing of Bazel. A source
carrying a builder's annotation is in it too, as is what its builders
generate, as build_runner writes a `.g.dart` beside its source, a part of the
same library: its codegen targets (see [Code generation](#code-generation))
are named for its path under `lib/` without `.dart`
(`src/model/user_codegen` for `lib/src/model/user.dart`), and the library
lists their outputs in `srcs`. A plain source and an annotated one may import
each other. A file one of those codegen targets produces is in no `srcs`, even when it is in the
source tree, as a published package carries it; any other file is a source,
whatever its name. No BUILD file may be under `lib/`, since one would cut the
package's library off from the files below it. Gazelle removes the rules it
wrote in one, as earlier versions wrote one per directory, and in fix mode
deletes the file; one holding anything else (a rule, an attribute or a
directive Gazelle does not write) fails the run, naming the file, so that you
move what it holds to the package's root. An imported file,
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

- **`# gazelle:dart_package_name my_app`** — the package's name, for a
  package whose `pubspec.yaml` does not state it or that has none. Gazelle
  writes it as the `package_name` of the package's `dart_package_metadata`.

- **`# gazelle:dart_language_version 3.13`** — the package's language
  version, likewise, as the metadata's `language_version`.

  Each of these two states a fact of the package of the BUILD file stating it,
  and holds in that directory and below it up to the root of another package
  (a directory with its own `pubspec.yaml` or `dart_package_metadata`), which
  states its own, as upstream each package's pubspec does.

- **`# gazelle:dart_build_yaml_ignore targets.$default.builders.json_serializable.generate_for`**
  — a part of the `build.yaml` beside the BUILD file that the build goes
  without (see [build.yaml](#buildyaml)).

- **`# gazelle:resolve dart foo //third_party:foo`** — overrides
  automatic dependency resolution for a Dart package (the `foo` of
  `package:foo/...` imports), mapping it to an explicit Bazel target.

#### pubspec.yaml and the package's metadata

Gazelle states a package's facts once, on the package's one
`dart_package_metadata` in the BUILD file at its root, which it names
`pubspec-metadata`, and every rule it writes for the package names it with
`package`: the library and codegen targets, and the binaries and tests in
every directory of the package, its root, `bin/`, `test/`, `tool/` and the
rest (`package = "//my_app:pubspec-metadata"`). It writes there:

- `package_name` and `language_version`: from a `pubspec.yaml` at the root
  (`name`, and the lower bound of `environment.sdk`), or the directives
  above, so most projects need no directives at all;
- `build_hook` and `link_hook`: the package's hooks (see [Hooks](#hooks));
- `license_file`: the root's `NOTICES`, or else `LICENSE`, by exact name, as
  `pub.from_lock()` chooses.

A package needs no `pubspec.yaml`. One that nothing states a fact of has no
metadata, and its rules name none: the rules name it after its root
directory. At the repository's root, which has no directory name, a package
with codegen targets gets one stating its library's name.

**The attributes above are output: each run rewrites them from
`pubspec.yaml`, the directives and the package's files, and `# keep` on one
makes it yours.** A `dart_package_metadata` already at the root is the
package's, whatever its name: Gazelle merges into it and keeps what it does not
write (`code_assets`, `version`), and fails when the root's BUILD file holds
two. One with no `pubspec.yaml` or directive
beside it is itself the source of its name and version. A `# keep` attribute,
a directive and the `pubspec.yaml` must agree: where two state a package's name
or language version differently, Gazelle reports each disagreement, naming both
values and where each is stated, and fails without writing any BUILD file. Gazelle
removes `package_name`, `language_version`, `build_hook`, `link_hook` and
`license_file` from the rules of a BUILD file written before the metadata held
them, and moves a library's `code_assets` onto the metadata.

#### build.yaml

For a package it writes codegen for, Gazelle reads the `build.yaml` at the
package's root, where build_runner finds its builder options, and writes each
bundled builder's `targets.$default.builders.<builder>.options` into the
`config` of the targets it writes for that builder, as the JSON object
build_runner would hand the builder:

```yaml
targets:
  $default:
    builders:
      json_serializable:
        options:
          field_rename: snake
```

```starlark
json_serializable_codegen(
    name = "user_codegen",
    srcs = ["lib/user.dart"],
    config = "{\"field_rename\":\"snake\"}",
    ...
)
```

The rest of the file has no place in a Bazel build: another target than
`$default`, a builder's `generate_for`, `enabled` or `dev_options`,
`global_options`, a builder Gazelle does not write targets for. A codegen
macro's `srcs` choose the files it runs on. Gazelle names every such part, by
its key path and line, and fails without writing any BUILD file:

```
gazelle: dart: build.yaml:9: `targets.$default.builders.json_serializable.generate_for` is not carried into the build: ...; to build without it, add `# gazelle:dart_build_yaml_ignore targets.$default.builders.json_serializable.generate_for` to the BUILD file in .
```

`# gazelle:dart_build_yaml_ignore <key path>`, one per part, in the BUILD file
beside the `build.yaml`, acknowledges that the build goes without that part,
and Gazelle carries the rest. An ignore that names no such part of that file
fails the run too, as does one stated twice. A package that keeps
`build.yaml` for build_runner alone has Gazelle not read it at all with
`# gazelle:exclude build.yaml` in its root's BUILD file. A `build.<name>.yaml`,
which build_runner reads only with `--config <name>`, fails the run until it
is excluded so. Options a `# gazelle:dart_builder_config` directive states
differently for the same builder are a disagreement, as for the package's
name.

#### Hooks

A package's `hook/build.dart` is its metadata's `build_hook`, and its
`hook/link.dart` its metadata's `link_hook`: Gazelle puts each hook in a
`filegroup` in `hook/` and names it on the package's `dart_package_metadata`.
A build hook fails every binary and test that reaches the package until the
metadata's `code_assets` supply what the hook would build (see
[Native code assets](#native-code-assets)); `code_assets` is yours: Gazelle
never writes or removes it. A link hook's imports are the `deps` of the
package's library,
for `dart_link_hook` to run it (see
[Recorded uses and link hooks](#recorded-uses-and-link-hooks)). A package
whose hook nothing here uses has Gazelle not see it, with
`# gazelle:exclude hook/build.dart` (or `hook/link.dart`) in its root's BUILD
file. Gazelle writes nothing else for `hook/`.

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

#### Test platforms

A test file's package:test `@TestOn` becomes its `dart_test`'s
`target_compatible_with`, so that Bazel skips the test on a platform
package:test would not run it on, rather than failing it: `dart test` on a
file whose `@TestOn` excludes the platform finds no tests and fails.

```dart
@TestOn('vm && !windows')
library;
```

```starlark
    target_compatible_with = select({
        "@platforms//os:windows": ["@platforms//:incompatible"],
        "//conditions:default": ["@rules_dart//dart/constraints:vm"],
    }),
```

Gazelle evaluates the selector as package:test does, over the platforms a
`dart_test` is built for: the Dart VM on Linux, macOS, Windows or another OS,
and the web platforms, which carry the `@rules_dart//dart/constraints:runtime`
value `js` or `wasm` and, as a browser has for package:test, no OS. It maps
`vm` (and `dart-vm`), `browser`, `js`, `wasm`, `linux`, `mac-os`, `windows`
and `posix`; a selector naming anything else (a browser by name, a compiler,
`android`), or accepting a set of platforms no list or single `select()`
states, fails the run, naming the file. Write the attribute by hand then,
marked `# keep`, as for any attribute Gazelle manages; Gazelle logs a
`target_compatible_with` it removes. A workspace whose tests name an OS needs
`bazel_dep(name = "platforms", ...)` for the `@platforms` labels.

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

### Without a pubspec.yaml

A rules_dart workspace needs no `pubspec.yaml` and no `pubspec.lock`. Every fact
a pubspec gives has a home in Bazel:

| The pubspec states | Bazel states it as |
| --- | --- |
| `name` | `package_name` on the package's `dart_package_metadata`; `# gazelle:dart_package_name` for Gazelle. With no `dart_package_metadata`, the package root directory's name. |
| `environment.sdk`, its lower bound | `language_version` on the `dart_package_metadata`, or `# gazelle:dart_language_version`. Unstated, the SDK's own. |
| `dependencies`, `dev_dependencies` | The `deps` of the target that imports the package, which Gazelle writes from the imports. |
| The versions in `pubspec.lock`, `dependency_overrides` | `pub.package()` pins, each with `version` and `sha256` (see [Using pub.dev packages](#using-pubdev-packages)). A pin in the root module decides. |
| `hook/build.dart`, `hook/link.dart` | `build_hook` and `link_hook` on the `dart_package_metadata`. |
| Native libraries a hook would build | `code_assets` on the `dart_package_metadata` (see [Native code assets](#native-code-assets)). |
| The license file | `license_file` on the `dart_package_metadata`. |
| `executables:` | A `dart_binary`. |

[`e2e/no_pubspec`](e2e/no_pubspec/) is the worked example, and a test in it
fails if a `pubspec.yaml` or `pubspec.lock` appears anywhere in the workspace.
Its `MODULE.bazel` pins `json_annotation` and `meta`; `app/BUILD.bazel` states
`app`'s name and language version once in a `dart_package_metadata`, which its
`json_serializable_codegen` and `dart_library` share, and `greet/BUILD.bazel`
states nothing, so `greet` is named for its directory.

Gazelle works without a pubspec. A package's root is the directory above its
`lib/`, `bin/` and `test/`, its name is the root directory's unless a
`dart_package_metadata` or `# gazelle:dart_package_name` states one, and an
import of `package:foo/...` becomes a dep on `@foo` (the repository
`pub.package(name = "foo")` creates), or on `@pub_deps//:foo` with
`# gazelle:dart_pub_deps_repo pub_deps`. Analysis, tests and code generation need
none either: what reads a pubspec reads one generated from the target's `deps`
and package record.

The price is pub's resolver. With no `pubspec.yaml` there is nothing for
`pub get`, `pub add`, `pub upgrade` or `pub outdated` to work on, and no lock, so
no tool chooses versions for you:

- Every third-party package is a `pub.package()` you write, with its `sha256`
  (`archive_sha256` in
  `https://pub.dev/api/packages/<name>/versions/<version>`, see
  [The sha256 of a `pub.package()`](#the-sha256-of-a-pubpackage)), and you pick its version.
- A pinned package is built with the dependencies its own pubspec states, and
  each must be pinned too: the transitive closure is yours to write, and a
  missing pin fails the fetch naming both packages.
- Upgrading means editing the version and digest by hand.
- A package you publish to pub.dev still needs its `pubspec.yaml`.

A workspace may mix both: a package with a pubspec and one without sit side by
side, and a `pub.package()` pin and a `pub.from_lock()` lock can supply one
package, the pin winning. Where a pubspec and a directive or
`dart_package_metadata` state the same fact differently, Gazelle fails and names
both (see [pubspec.yaml](#pubspecyaml)).

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
    package = ":pubspec-metadata",
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
    package = ":pubspec-metadata",
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
`mockito`, `copy_with_extension_gen`, `stacked`, `drift`), each ships a convenience macro (`json_serializable_codegen`,
`freezed_codegen`, …) under `dart/ext/<builder>/defs.bzl`. It writes the
builder's codegen targets for its `srcs` and names what they generate, which
the `dart_library` holding the sources lists in its own `srcs`:

```starlark
load("@rules_dart//dart/ext/json_serializable:defs.bzl", "json_serializable_codegen")

json_serializable_codegen(
    name = "user_codegen",
    srcs = ["lib/user.dart"],
    asset_deps = ["lib/role.dart"],  # the package's files user.dart imports
    package = ":pubspec-metadata",
)

dart_library(
    name = "my_pkg",
    srcs = ["lib/role.dart", "lib/user.dart", ":user_codegen"],
    package = ":pubspec-metadata",
    deps = ["@pub_deps//:json_annotation"],
)
```

A generator sees its package's other files through `asset_deps`, not through
a library, since the library holds what it generates; `deps` are the other
packages' libraries. Gazelle discovers
the matching annotations in sources and emits the macro automatically. See
[`docs/ext.md`](./docs/ext.md) for the shim contract, worker behaviour, and
the guards for generated files checked into a source tree. Two more
`dart/ext` packages are not builders but Bazel builds of a package's native
library: `sqlite3` (`sqlite3_code_asset()`) and `webcrypto` (see
[Native code assets](#native-code-assets)).

#### A generator and its package

A generated file is part of the package whose sources it was generated from, so
a codegen rule and the `dart_library` collecting its output name the same
`dart_package_metadata`, and the build fails naming both when they do not. The
generator runs at the package's language version: the one its
`dart_package_metadata` states, else the SDK's own, which is what the analyzer
and the format check assume too.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_codegen", "dart_library", "dart_package_metadata")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_pkg",
    language_version = "3.11",
)

dart_codegen(
    name = "user_g",
    src = "lib/user.dart",
    package = ":pubspec-metadata",
    generator = "//tools:gen.dart",
    output_suffixes = [".g.dart"],
)

dart_library(
    name = "my_lib",
    srcs = ["lib/user.dart", ":user_g"],
    package = ":pubspec-metadata",
)
```

Because `package` names a target, the rules naming it can sit in different
BUILD files. The builder macros (`json_serializable_codegen` and friends) take
`package` too and forward it to every rule they emit.

This is not `pub.package()`, which fetches a published package from pub.dev;
`dart_package_metadata` states facts about a package you are building yourself.

#### Executables in a package

Dart gives every file under a package's root to that package, `bin/` and
`test/` included, so an entrypoint there compiles at the package's language
version. A `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary`
says which package it is in by naming the package's `dart_package_metadata`
with `package`, as a library does. Its package is then rooted at the
declaration's package root, wherever the executable's own BUILD file is:

```starlark
# greeter/test/BUILD.bazel
dart_test(
    name = "greeter_test",
    main = "greeter_test.dart",
    package = "//greeter:pubspec-metadata",
    deps = ["//greeter", "@pub_deps//:test"],
)
```

The entrypoint compiles, analyzes and is format-checked at the package's
version, whether or not the executable depends on a library of the package. An
executable naming no `dart_package_metadata` adds no package of its own: its
entrypoint takes the version of a package its `deps` bring whose root contains
it, or else the SDK's. The build fails naming both sides when an executable's
package contradicts its `deps`: a package in `deps` rooted at the same
directory must be the same package; one with the same name must be rooted
there; and each of the executable's own files must sit under the package root
and not inside another package's.

### Static analysis and formatting

`dart analyze` and the `dart format` check run as an aspect, `dart_analyze`,
over every Dart target a `bazel test` names. The analyzer's lints are those the
`analysis_options.yaml` files enable ([Lints](#lints)), `dart_fix` applies the
analyzer's fixes, `dart_format` rewrites files to the format check's settings,
and analysis and fixes run in [persistent workers](#analysis-workers). Enable the
aspect in `.bazelrc`, and list every `analysis_options.yaml` in the repository in
one `dart_analysis_config`:

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

The format check runs `dart format` over the same files, and fails the build
if formatting would change any of them. Its settings are
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
each target at its own package's `language_version` (set on its
`dart_package_metadata`; Gazelle copies it from `pubspec.yaml`). An
executable's entrypoint takes the version of the package it names with
`package`, or else of the package its `deps` bring whose root directory
contains it (see [Executables in a package](#executables-in-a-package)). With no version
stated, the check uses the newest the SDK knows, so a package on an older
version must state it for the check to hold it to the style its own
`dart format` produces.

#### Formatting and fixing

`@rules_dart//dart/format` writes into your sources what the format check
computed for the targets you name: every file it would reject, formatted with
its own options and at its own target's language version. The rewrite is the
check's own output, so after a run the check passes. `@rules_dart//dart/fix`
does the same for `dart fix --apply`: the analyzer's automated fixes, the same
quick-fixes an IDE offers, driven by the lints your options enable and
computed over the project the analysis stages for each target.

```sh
bazel run @rules_dart//dart/format -- //...                 # every target of the workspace
bazel run @rules_dart//dart/format -- -- //app/... -//app/gen/...
bazel run @rules_dart//dart/format -- --config=deep //:slow_test
bazel run @rules_dart//dart/fix -- --dry-run //app:lib      # print the fixes as a diff
bazel run @rules_dart//dart/fix -- $(bazel query 'kind(dart_library, //app/...)')
```

After an optional `--dry-run`, the arguments are those of `bazel build`: its
flags and target patterns, relative to the directory you run from, with `--`
before patterns that start with `-`, as `bazel build -- //app/... -//app/gen/...`
needs. Each tool runs `bazel build` with them and the `dart_analyze` aspect,
and writes the result, so it formats or fixes the targets that build would
build. Flags given to `bazel run` itself build the tool, not those targets:
pass them after the `--`. A target your `.bazelrc` leaves out with
`--build_tag_filters` is left out here too, even when named, as `bazel build`
leaves it out; pass the config that includes it. The tool sets
`--aspects`, `--output_groups`, `--run_validations` and
`--build_event_json_file` itself and refuses them. A `bazel query` prints
labels, so its output works as the arguments. The build reads your `.bazelrc`
as any other does, which is why the `analysis_config` line goes under
`common`: under `test` alone the tools would format and fix with no options.
Only each target's own hand-written files are written, as only they are
checked; a target tagged `no-dart-format` is not formatted, and one tagged
`no-dart-analyze` can still be fixed. Generated files are never written: only
files Bazel records as sources are eligible, so codegen output stays
resolvable to its importers without being edited. A fix can make further
fixes possible, so run `fix` until it fixes nothing.

Nothing is written unless everything can be. Each change records the bytes it
was computed from, and a file that changed since the build, or one two targets
would rewrite differently, refuses the whole run.

#### Lints

Lints are the rules an `analysis_options.yaml` enables, as in any Dart project;
the analyzer reads that file and the package's `pubspec.yaml` plays no part. A
ruleset published as a package, such as `package:lints` or
`package:very_good_analysis`, is included by `package:` URI, and its package goes
in the `deps` of the `dart_analysis_options` that holds the file:

```yaml
# analysis_options.yaml
include: package:lints/recommended.yaml
analyzer:
  language:
    strict-casts: true
linter:
  rules:
    - prefer_final_locals
```

```starlark
dart_analysis_options(
    name = "analysis_options",
    src = "analysis_options.yaml",
    deps = ["@pub_deps//:lints"],  # `@lints` for a `pub.package(name = "lints", ...)`
)
```

Gazelle writes these `deps` from the `include:` lines (see
[Analysis options](#analysis-options)). The ruleset is staged to resolve the
include alone: it is not a dependency of the code it lints, and it is not itself
analyzed. A lint that reads the pubspec reads one generated for the analysis
from the target's `deps` and its package's `language_version`, so
`depend_on_referenced_packages` is satisfied by `deps` and `sdk_version_since`
judges the code against the version the package compiles at. `// ignore:`
comments and `analyzer: errors:` settings work as in an IDE; `no-dart-analyze`
skips a whole target.

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

Bazel's own worker flags apply: `--worker_max_instances=DartAnalyze=N` (and
`DartFix=N` for fixes) sets how many servers run at once (each holds a few
hundred MB), and `--strategy=DartAnalyze=sandboxed`, or remote execution, runs
each action once on its own server.

#### Analysis against summaries

Each target is analyzed against analyzer summaries of its dependencies, not
their source. A summary records a library's declarations without its function
bodies, comments or source positions, and every library gets one, written by
an action of its own. An edit inside a function body, or to a comment, leaves
the library's summary unchanged, so Bazel re-analyzes that library's own
target and no target above it. An edit that changes a declaration, a private
one included, changes the summary and re-analyzes the targets that depend on
it.

This uses parts of the analyzer that the Dart SDK does not support. The SDK
removed the analyzer's own way of analyzing against summaries, its "build
mode", in 2021
([dart-lang/sdk@00a45e4](https://github.com/dart-lang/sdk/commit/00a45e425a7d944ad0da5f9417e21d760bf9235e),
"Remove build mode from analyzer_cli"), and then the `dartanalyzer` tool that
offered it in Dart 2.18
([dart-lang/sdk#46100](https://github.com/dart-lang/sdk/issues/46100)). No SDK
command reads summaries today, and `package:analyzer` offers reading and
writing them only in its private `src/` API. So rules_dart builds its own
analyzer on the SDK's `pkg/analyzer` and `pkg/linter`, unmodified, from the
source archive of the SDK's release tag (`dart_analyzer_source`), and reports
what that release's `dart analyze --fatal-infos` reports.

Analyzing against summaries hits known analyzer bugs, and the summary analyzer
fails the analysis, with the reason and this flag, wherever it can tell the
answer is wrong:

- **Crashes.** The analyzer crashes on some code that uses a dependency's
  declarations, such as a public nullable field that is not promoted, or a
  `const` constructor of a dependency whose evaluation fails. The library would
  get no diagnostics at all. The analysis fails with the crash. The known
  crashes happen only on code with a compile error.
- **Swallowed exceptions.** An exception in a lint rule is caught and ignored
  by the analyzer, losing the rule's diagnostics. The analysis fails with it.
- **`base` and `final` class modifiers.** The analyzer does not report a class
  that subtypes a dependency's `base` or `final` class without being `base`,
  `final` or `sealed` itself (`subtype_of_base_is_not_base_final_or_sealed` and
  its relatives). The summary analyzer finds those classes and fails with the
  error the analyzer would have reported.
- **`prefer_relative_imports` in a package split across targets.** The lint
  does not fire for a `package:` import of the same package's file in another
  target. With the lint on, the summary analyzer finds those imports and fails.
- **`comment_references` from doc imports.** A name that an `@docImport` brings
  in from a dependency or from the SDK is reported as not in scope. Analysis
  fails on the diagnostic anyway, and the summary analyzer says which ones are
  false.
- **Context messages.** A diagnostic's context message that points into a
  dependency ("'x' refers to a public property", "the error is in the field
  initializer of 'E'") loses its location or is left out. The diagnostic itself
  is reported as it would be.
- **Plugins and data-driven fixes.** Analyzer plugins and validation of
  `lib/fix_data.yaml` run only in the analysis server, which cannot read
  summaries; a target whose options enable a plugin, or whose package has a
  `lib/fix_data.yaml`, fails.

These are the losses found by comparing analysis from summaries with
analysis from source over this repository, its examples, 92 pub packages and
the analyzer's and linter's own tests, on Dart 3.13.7. A loss nobody has found
cannot be detected; analyzing with the flag off is the reference.

The summary analyzer must be built from the same SDK release as the Dart
toolchain: the `dart` extension registers it for its own SDK. A Dart SDK with
no release tag (Flutter's beta and main channels, a local build) has no
unmodified analyzer source to build it from, so analysis fails, naming this
flag, unless you register a `dart_analyzer_toolchain` built from its checkout
(`dart_analyzer_source(path = ...)`). Every library declares its summary, so
with the flag on any build configures the summary analyzer and fetches the
SDK's source archive it is built from (the same archive the outline stripper is
built from, kept in the repository cache), as rules_java and rules_go fetch
their toolchains' tools; nothing is built until an analysis reads a summary,
and a failure to build it fails only that analysis. To analyze against
dependencies' source, with the SDK's own `dart analyze`:

```sh
bazel test //... --@rules_dart//dart:analysis_summaries=false
```

`@rules_dart//dart/fix` always runs the SDK's own `dart fix`, from source.

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

The variants are separate `dart_library` targets of packages with the same
`package_name`, each in its own directory, so the import is the same whichever is picked.
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

### Native code assets

A Dart package that needs native code usually builds it in a
`hook/build.dart`. rules_dart does not run a package's build hook; a native
library is built by Bazel and bound to the id the Dart bindings use. The chain
is `cc_library` → `cc_shared_library` → `dart_code_asset` → `code_assets`:

```starlark
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_code_asset")

cc_library(
    name = "counter",
    srcs = ["counter.cc"],
)

cc_shared_library(
    name = "counter_shared",
    # A Windows DLL exports nothing unless told to.
    features = select({
        "@platforms//os:windows": ["windows_export_all_symbols"],
        "//conditions:default": [],
    }),
    deps = [":counter"],
)

dart_code_asset(
    name = "counter_asset",
    asset_id = "package:counter/counter.dart",  # the id the `@Native` bindings declare
    shared_library = ":counter_shared",
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    code_assets = [":counter_asset"],
)
```

The `asset_id` is the id the bindings resolve against: the `package:` URI of the
library that declares the `@Native` functions, or the one its `@DefaultAsset`
names. Every `code_assets` entry provides `DartCodeAssetInfo`, which
`dart_code_asset` does.

- Name the asset in the `code_assets` of the `dart_binary` or `dart_test` that
  runs the code, or in the `dart_package_metadata` of the package that owns the
  bindings, from where it reaches every binary and test depending on any
  library of that package, and every one in the package (its `package`), as
  upstream treats the root package like any other. A package has one `dart_package_metadata`, so its
  assets are one set for all its libraries; assets that differ between programs
  (a test's stub library, a build for another platform) are not a fact of the
  package, and are the `code_assets` of the executable, which replace the
  package's by id. Do not declare a second `dart_package_metadata` to vary them. A binary's libraries
  are linked into `<name>.native/` beside the executable, which must be
  installed with it (`cp -RL`, since they are links); a test finds them in
  runfiles.
- An entry in a target's own `code_assets` replaces the asset of the same id
  that its `deps` bring, so a test can load a differently built library under
  the id a package declares. Two different assets for one id from `deps` fail,
  naming both.
- `link_mode` is `dynamic_loading_bundle` by default, a library Bazel builds and
  ships with the program. `dynamic_loading_system` (with `system_uri`),
  `dynamic_loading_executable` and `dynamic_loading_process` look the symbols up
  in the executable or the running process. `static` is refused.
- A package whose `hook/build.dart` has no Bazel replacement fails any
  `dart_binary` or `dart_test` that reaches it, naming the package. For a pub
  package, rules_dart sees the hook; supply a replacement with
  `pub.from_lock(resolve = ...)`, or, if its native code is not used, list it in
  `pub.from_lock(ignore_hooks = [...])` or set `pub.package(ignore_hook = True)`.
  Your own package states its hook with `build_hook` on its
  `dart_package_metadata`, since a rule cannot look for files (Gazelle states
  it for you, see [Hooks](#hooks)), and replaces it with the `code_assets` of
  the same `dart_package_metadata`; a binary's or test's own `code_assets` do
  not replace a package's hook:

  ```starlark
  dart_package_metadata(
      name = "pubspec-metadata",
      package_name = "bindings",
      build_hook = "hook/build.dart",
      code_assets = [":counter_asset"],
  )

  dart_library(
      name = "bindings",
      srcs = glob(["lib/**/*.dart"]),
      package = ":pubspec-metadata",
  )
  ```
- A build tool that never loads native code sets `code_assets_from_deps = False`
  on its `dart_binary`, so it neither builds the libraries in its dependency
  closure nor hits that error.

rules_dart ships replacements for two packages, under `dart/ext`:
`sqlite3_code_asset()` from `@rules_dart//dart/ext/sqlite3:defs.bzl`
(`package:sqlite3` 2.0.0 and later) and `@rules_dart//dart/ext/webcrypto:code_asset`
(`package:webcrypto` 0.6.1). `pub.from_lock()` attaches them to a lock that
pins those versions, so a program using `package:sqlite3` needs nothing more
than the dependency. Naming one explicitly, as the
[`sqlite3_binary`](e2e/ext_exemplar/sqlite3_binary/) exemplar does, builds the
same library for that target:

```starlark
load("@rules_dart//dart/ext/sqlite3:defs.bzl", "sqlite3_code_asset")

dart_binary(
    name = "app",
    main = "bin/main.dart",
    code_assets = [sqlite3_code_asset()],
    deps = ["@pub_deps//:sqlite3"],
)
```

### Recorded uses and link hooks

A package can ship a `hook/link.dart` that decides what to include from how the
program uses the package: the compiler records each constant instance of a
`@RecordUse` class (and each constant call to a `@RecordUse` static method)
that survives tree-shaking. `dart_binary(record_use = True)` writes those uses
beside the executable, and `dart_link_hook` runs the link hooks in its `deps`
over them and collects the data assets they emit.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_library", "dart_link_hook", "dart_package_metadata")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "glyphs",
    link_hook = "hook/link.dart",
)

dart_library(
    name = "glyphs",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
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

Uses are recorded in the `exe` and `aot-snapshot` modes; in `kernel` the hooks
see none. The data assets a hook emits are declared by
id in `data_assets`, since Bazel names every output before the hooks run; the
build fails if a hook emits a different set, or if it fails itself, with the
hook's message. The program's own package is linked like those in `deps`: name
it in `package`, as the `dart_binary` in `recorded_uses` does (the two must
agree), and its hook runs. A link hook's imports are `deps` of the package's
library, as pub requires, or of the program for its own package's hook, which
may also import the program's own files under the package's `lib/`. Pub packages that ship a link hook get `link_hook` set by
`pub.from_lock()`, and Gazelle sets it for your own (see [Hooks](#hooks)).

## Flags

Every command-line setting rules_dart reads. Set one per invocation or in
`.bazelrc` (`common --@rules_dart//dart:<name>=<value>`). All but
`modular_kernel` and `outline_kernel` describe the program being built, not the
tools that build it: they do not reach the exec configuration, so build tools
(codegen builders, any `cfg = "exec"` Dart tool) are built the same whatever
they are set to.

| Flag                                               | Default | What it does                                                                                                                                                  |
| -------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--@rules_dart//dart:analysis_config=<label>`      | none    | The `dart_analysis_config` whose options analysis, fixes and formatting use.                                                                                  |
| `--@rules_dart//dart:analysis_summaries`           | on      | Analyzes each target against analyzer summaries of its dependencies (see [Analysis against summaries](#analysis-against-summaries)); off analyzes their source. |
| `--@rules_dart//dart:analysis_worker`              | on      | Runs analysis and fixes in persistent workers, one analysis server each; off runs `dart analyze`/`dart fix` per action.                                       |
| `--@rules_dart//dart:extra_dart_defines=KEY=VALUE` | none    | Adds an environment declaration to every Dart compile, after target `defines`; repeat for more.                                                               |
| `--@rules_dart//dart:kernel_list`                  | on      | Runs each test from a kernel list naming the kernels it reaches; off stores one joined kernel per test.                                                       |
| `--@rules_dart//dart:modular_kernel`               | on      | Compiles each library once into kernel modules that tests link; off compiles each test's whole program from source and stops checking imports against `deps`. |
| `--@rules_dart//dart:outline_kernel`               | on      | Compiles dependents against outlines of their dependencies' modules, made by the outline toolchain of the Dart SDK; off compiles them against full kernels.   |
| `--@rules_dart//dart:runner_snapshot`              | off     | Starts the `package:test` runner from a snapshot cached on the machine (see [Tests](#tests)); off starts it from its kernel and touches no cache.             |
| `--@rules_dart//dart:track_creation_locations`     | off     | Compiles VM kernels with `--track-creation-locations` (`--track-widget-creation`).                                                                            |

## Examples

The [`e2e/`](e2e/) directory contains complete working examples:

| Example                                                     | What it demonstrates                                                                            |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [`hello_world`](e2e/hello_world/)                           | Minimal binary + all compile modes (`exe`, `aot-snapshot`, `kernel`)                              |
| [`no_pubspec`](e2e/no_pubspec/)                             | No `pubspec.yaml` anywhere: codegen, analysis, format, fix, tests, every binary                 |
| [`library_deps`](e2e/library_deps/)                         | Transitive `dart_library` dependencies, `srcs` attribute                                        |
| [`dart_test`](e2e/dart_test/)                               | Tests with and without deps, `srcs` for test helpers                                            |
| [`analysis`](e2e/analysis/)                                 | The `dart_analyze` aspect's checks with `package:`-included options                             |
| [`fix`](e2e/fix/)                                           | `@rules_dart//dart/fix` and `format` write-back, and that generated files are never rewritten   |
| [`analyze_composition`](e2e/analyze_composition/)           | A lint ruleset and page width shared from another Bazel module                                  |
| [`web_app`](e2e/web_app/)                                   | JavaScript and WebAssembly compilation with library deps                                        |
| [`web_compiler`](e2e/web_compiler/)                         | Per-compiler code by `select()`, and the resets other modules' rules use                        |
| [`pub_deps`](e2e/pub_deps/)                                 | Single pub.dev package via `pub.package()`                                                      |
| [`pub_lock`](e2e/pub_lock/)                                 | Multiple packages from `pubspec.lock` via `pub.from_lock()`                                     |
| [`gazelle`](e2e/gazelle/)                                   | Automatic BUILD file generation with Gazelle                                                    |
| [`cross_compile`](e2e/cross_compile/)                       | Cross-compilation to other platforms via `platform_data` transition                             |
| [`dart_test_pkg`](e2e/dart_test_pkg/)                       | `dart_test` with pub dependencies via `pub.from_lock()`                                         |
| [`pub_lock_dedup`](e2e/pub_lock_dedup/)                     | Cross-lock-file package deduplication                                                           |
| [`pub_lock_upgrade`](e2e/pub_lock_upgrade/)                 | Locks that disagree build the highest version, rules_dart's own lock included                   |
| [`pub_lock_conflict`](e2e/pub_lock_conflict/)               | `check_direct_dependencies = "error"` fails a raised root lock, giving the command to raise it  |
| [`pub_lock_cross_module`](e2e/pub_lock_cross_module/)       | `pub.from_lock()` across Bazel module boundaries                                                |
| [`pub_lock_cycle`](e2e/pub_lock_cycle/)                     | Packages that depend on each other: a curated cycle (`dio`), and one the root declares          |
| [`pub_package_cycle`](e2e/pub_package_cycle/)               | `pub.package()` packages that depend on each other, built as one library                        |
| [`pub_cycle_refused`](e2e/pub_cycle_refused/)               | An undeclared cycle, a stale declaration and part of a cycle fail, naming the declaration       |
| [`pub_member_kind`](e2e/pub_member_kind/)                   | Another rule set's own pub package kind, in a cycle, over the public pub surface                |
| [`toolchain_pin_conflict`](e2e/toolchain_pin_conflict/)     | A root `dart.toolchain` pin below a dependency's request fails, naming the dependency           |
| [`pub_lock_unsupplied`](e2e/pub_lock_unsupplied/)           | A hosted package depending on an unsupplied sdk package fails, naming it                        |
| [`pub_lock_resolve`](e2e/pub_lock_resolve/)                 | `resolve` serving a `path` package and replacing a hosted one for the whole graph               |
| [`pub_lock_resolve_invalid`](e2e/pub_lock_resolve_invalid/) | Unnamed, twice-named and wrongly named `path` packages and a stale `resolve` key fail           |
| [`pub_lock_path`](e2e/pub_lock_path/)                       | `path` packages built from their pubspec, ignored, or refused for having a BUILD file           |
| [`pub_hub_surface`](e2e/pub_hub_surface/)                   | Every locked package in its hub, including one declared with `pub.package()`                    |
| [`pub_package_missing_dep`](e2e/pub_package_missing_dep/)   | A `pub.package()` whose pubspec depends on an unsupplied package fails, naming both             |
| [`kernel_source_refused`](e2e/kernel_source_refused/)       | A `dart_kernel_source` with both or neither of `dart_version` and `path`, or no checkout, fails |
| [`pub_override_root_lock`](e2e/pub_override_root_lock/)     | The root's lock wins over a dependency module's `pub.package()`                                 |
| [`pub_highest_wins`](e2e/pub_highest_wins/)                 | The highest request builds, over root and dependency `pub.package()`s, warning for the root's   |
| [`pub_root_older_lock`](e2e/pub_root_older_lock/)           | Under `check_direct_dependencies = "error"`, a dependency raising the root's lock fails         |
| [`pub_root_newer`](e2e/pub_root_newer/)                     | A root lock above a dependency's `pub.package()` wins, silently                                 |
| [`codegen`](e2e/codegen/)                                   | `dart_codegen`/`dart_aggregate_codegen` over parts, re-exports and source sets                  |
| [`ext_exemplar`](e2e/ext_exemplar/)                         | One package per bundled `dart/ext` builder, plus native `code_assets`, sqlite3/webcrypto        |
| [`link_hook`](e2e/link_hook/)                               | `record_use` and a package's `hook/link.dart` emitting a data asset via `dart_link_hook`        |

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile via
> `--platforms`. `kernel` is a VM format that ignores target
> flags. Built natively, a `kernel` or `aot-snapshot` target's
> executable is a launcher that runs the output in the SDK's VM, so it works with
> `bazel run` and as `data`; cross-compiled, the target's executable is the
> output itself, for the target's own runtime to run. Linux targets are `linux-x64`, `linux-arm64`, `linux-riscv64` and
> `linux-arm` (armv7, selected by `@platforms//cpu:armv7`), reachable from every
> supported host. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
