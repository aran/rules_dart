# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## What's New

- **Many breaking API changes.** See detailed changelog notes. In general the
  reasons are:
  - More idiomatic Bazel APIs
  - Improving consistency across rules_dart and rules_flutter
  - Handling various edge cases
  - Added features where the new feature's ideal name was already taken
- **Support for git and path packages from pubspec.**
- **Deeper Bazel integration.** Integration into RBE, coverage, and some other
  niche features like automatic execution groups. RBE is big because you can
  offload Dart and Flutter build and test work to big machines in the cloud.
  Several changes to improve hermeticity. With standard Bazel exceptions,
  anything non-hermetic in these rules is a bug.
- **Faster Dart analysis.** The main improvement is the addition of analysis
  summaries, which means making a "summary" of each Dart package that analysis
  can cache and reuse, and avoid reanalysis if they haven't changed. This is a bit risky because it's not
  supported by core Dart. It gives fast `dart analyze` even on large codebases,
  at the risk of encountering some Dart SDK bugs. It's on by default; turn it
  off with `--@rules_dart//dart:analysis_summaries=false`. Other speed
  improvements include using persistent analysis workers.
- **Unused dependencies check.** Helpful for optimizing builds.

### Migrating from 0.8

Summary of what to do, with details below. Running Gazelle
after step 1 does steps 6–8 and 23 for the BUILD files it writes.

**MODULE.bazel**

1. `@rules_dart//gazelle/dart` → `bazel_dep(name = "rules_dart_gazelle_plugin")`,
   loaded as `@rules_dart_gazelle_plugin//dart`. `gazelle` and `rules_go` now
   come with that module, not with rules_dart.
2. Dart SDK 3.11.x/3.12.x → 3.13.2 or later. The root's `dart.toolchain` pin
   is now used exactly; `allow_upgrade_by_dependencies = True` restores
   raising it.
3. `pub.from_lock(on_version_conflict = ...)` → removed; the highest version
   any module or lock asks for is built. `ignore_hooks` in a module other
   than the root → fails.
4. `pub.package(deps = ...)` → removed; dependencies come from the package's
   pubspec. A `pub.package()` whose `hook/build.dart` nothing replaces now
   fails: `ignore_hook = True` if its native code is unused.
5. A lock with `path` packages → list each in `pub.from_lock(resolve = ...)`,
   `build_from_pubspec = [...]` or `ignored = {...}`. Packages that depend on
   each other → `pub.cycle()` (the error gives it). A lock with no `sha256`
   for its hosted packages (written by a pub older than 2.19) → re-resolve it
   with `bazel run @rules_dart//dart/pub -- get`.

**BUILD files**

6. Package facts on rules (`package_name`, `language_version`, `version`,
   `link_hook`, `has_unreplaced_hook` and `code_assets` on `dart_library`, and
   the first two on `dart_binary`, `dart_test`, the web binaries and codegen
   rules) → one `dart_package_metadata` per package (stating `version`,
   `license_file`, `build_hook`, `link_hook`, `code_assets`, `data_assets`),
   and `package` naming it on each target. Gazelle writes it at the package
   root as `pubspec-metadata`.
7. Gazelle now writes one `dart_library` per package, at its root, holding
   all of `lib/`. Hand-written splits still work: several `dart_library`s at
   the root or under `lib/`, each naming the same metadata, with an import
   across them failing unless the importer `deps` on the holder.
8. `<builder>_library` codegen macros (`json_serializable_library`,
   `freezed_library`, …) → `<builder>_codegen`, whose outputs go in the
   `dart_library`'s `srcs`. `go_router_library` → removed (rules_flutter ships
   it).
9. `@rules_dart//dart/ext/_shared:defs.bzl` → `@rules_dart//dart/ext:defs.bzl`;
   the combining shim → `@rules_dart//dart/ext/combining_shim:bin`;
   `shared_part_library`/`library_builder_library` → `shared_part_codegen`/
   `library_builder_codegen`.
10. `dart_format` / `dart_fix` targets → `bazel run @rules_dart//dart/format --
    <patterns>` / `bazel run @rules_dart//dart/fix -- <patterns>`.
11. `dart_binary(compile_mode = "jit-snapshot")` → `"kernel"`,
    `"aot-snapshot"` or `"exe"`. `$(location)` of a `kernel`/`aot-snapshot`
    binary now names a launcher. `dart_compile_flags = ["--save-debugging-info"]`
    → `--@rules_dart//dart:split_debug_info`; `--resolve-dwarf-paths` in
    them → refused.
12. `dart_binary.code_assets_from_deps` → `code_assets_from_packages`.
13. `dart_test.yaml` → attributes on the `dart_test` (`include_tags`,
    `exclude_tags`, `tags`, …). Tests now run in their package's root, as
    `dart test` does: fix paths that assumed the workspace root. A test
    running SDK commands adds `@rules_dart//dart` to its `data`.
14. `dart_link_hook` → `dart_program_assets`, providing
    `DartProgramAssetsInfo` in place of `DartDataAssetInfo`; its output,
    `<name>.program_assets`, lists what ships for `ProgramAssets.read`
    (`@rules_dart//dart/program_assets`). It takes the program's own
    `package`, which must be the recording `dart_binary`'s; that package's
    link hook now runs too.
    `dart_link_hook.data_assets` → removed; an id a rule names at analysis
    time goes in the `link_hook_assets` of its package's
    `dart_package_metadata`, which the hook must always emit.
15. Gazelle: `# gazelle:dart_package_name`/`dart_language_version` stop at a
    nested `pubspec.yaml`; a package's root is its innermost pubspec;
    `build.yaml` parts Gazelle cannot carry fail until handled or marked
    `# gazelle:dart_build_yaml_ignore <key path>`. A package name or language
    version that `pubspec.yaml`, a directive and the metadata state
    differently fails the run. Gazelle now writes a `dart_test`'s `tags` from
    `@Tags` and its `target_compatible_with` from `@TestOn`: mark hand-written
    ones `# keep`.
16. A package's own `hook/build.dart` → Gazelle states it as the metadata's
    `build_hook`, which fails the package's binaries and tests until the
    metadata's `code_assets` or `data_assets` replace it; an unused hook →
    `# gazelle:exclude hook/build.dart`.
17. An import by `file:` URI, with a query or fragment, or by a relative path
    into `lib/` from outside it (`../lib/a.dart`), and a `part` its
    `dart_library` does not hold → fail the import check; import by
    `package:` URI.
18. `Runfiles.rlocation` (`@rules_dart//dart/runfiles`) of a path with `.` or
    `..` segments → throws, as Bazel's runfiles libraries do.
19. `@rules_dart//dart/ext/tools:check_dual_build_collisions` → removed; the
    build generates the code, and `build_runner` does not run beside it.
20. `dart_source_set` → removed; assemble the directory with bazel_lib's
    `copy_to_directory` (same `srcs`, `root_paths`, `replace_prefixes`) and pass
    it to `dart_library.srcs_dir`.
21. Analysis now reads dependencies' analyzer summaries. If a project hits
    an SDK summary bug, `--@rules_dart//dart:analysis_summaries=false`.
    `--@rules_dart//dart:analysis_shutdown_workaround` → removed; analysis
    runs in persistent workers (`analysis_worker=false` for a process each).
22. `dart_code_asset.shared_library` → `file`; `dart_code_asset.system_uri` →
    `uri` (upstream `CodeAsset.file` and `DynamicLoadingSystem.uri`).
23. `generator_bin` on `dart_codegen`, `dart_aggregate_codegen` and
    `dart_sqlcodegen` → `generator`. A `.dart` script as `generator` or
    `generator_script` → a `dart_binary` whose `main` calls `shimMain` with a
    `package:build` Builder (see `docs/ext.md`); its flags → `config` options.
24. A dep that none of a target's files imports → fails the build; remove it
    from `deps`. A dep needed without an import → `features =
    ["-dart_unused_deps"]` on the target (see [Deps match imports](#deps-match-imports)).
    `bazel run @rules_dart//dart/unused_deps -- //...` removes such deps.

**Rule authors** (`@rules_dart//dart:utils.bzl` and providers)

25. `DartCodeAssetInfo.dynamic_library` → `file`; `DartCodeAssetInfo.system_uri`
    → `uri`.
26. `DartPackageInfo.lib_root` → `package_root`; `derive_lib_root` →
    `derive_package_root`; `has_unreplaced_hook` → `unreplaced_hook`.
27. `DartInfo.package_name`/`lib_root` → `DartInfo.packages` (from
    `DartPackageInfo(...)`); `DartInfo.deps` values are tuples of package
    names. Build `DartInfo` with `dart_info(ctx = ctx, ...)` and merge
    `SUMMARY_ATTRS` into the rule's attributes.
28. `dart_analyzable_info` → `dart_analyzable_info_no_package` (`srcs` →
    `entry_srcs`); `dart_analyzable_info_with_package` → `dart_analyzable_info`
    (takes `packages`); `DartAnalyzableInfo.srcs` → `entry_srcs`,
    `package_srcs` → `DartInfo.srcs`.
29. `module_defines_transition` → `executable_defines_config`;
    `dart_entry_kernel_action` takes no `defines` and needs
    `MODULAR_KERNEL_ATTR`.
30. `dart_link_hook_actions(ctx, runner, recorded_uses, deps, data_asset_ids,
    name)` → `dart_program_assets_actions(ctx, package, deps, name,
    recorded_uses)` (a `DartRecordedUsesInfo`, or `None` not to link), whose
    `info` is a `DartProgramAssetsInfo`; `link_hook_runner_attr()` →
    `program_assets_attrs()`, beside `PROGRAM_ASSETS_TOOLCHAINS` and
    `fragments = ["cpp"]`. `collect_transitive_code_assets`,
    `resolve_code_assets` and `code_asset_identity` → removed; the code
    assets a program's kernel maps are `program_kernel_code_assets(info)`, with
    the rule's own as `dart_program_assets_actions()`'s `code_assets` argument.
31. `DartKernelSdkInfo.runtime` → `aot_runtime`; `platform`/`defines` →
    `runtimes` (from `dart_kernel_runtime`).
32. `dart_toolchain.sdk_root`, `DartSdkInfo.sdk_root`/`tool_files` →
    `dart_toolchain.sdk` takes a `dart_sdk_files`; read `DartSdkInfo.files`.
    A Dart SDK with no release tag also needs a `dart_outline_toolchain` and a
    `dart_analyzer_toolchain`, or `outline_kernel` and `analysis_summaries`
    off (see [A Dart SDK of your own](#a-dart-sdk-of-your-own)).
33. `parse_pubspec_deps`/`parse_pubspec_sdk_constraint`/
    `derive_language_version` → `read_pubspec` in `//dart/pub:pubspec.bzl`.
    `dart/pub/pub_lock_hub.bzl` → private.
34. `colocate_entrypoint` → removed; a binary compiles its sources in place.
35. Loads of `dart/private/**` or `dart/pub/private/**` from outside rules_dart
    → fail; load the public `.bzl` files instead.
36. A dep that is used without an import (a plugin registered by native
    code) → its rule returns `DartUsedWithoutImportInfo`. A library rule
    whose `deps` are what its `srcs` import → checks itself with
    `library_import_check` and `LIBRARY_IMPORT_CHECKER_ATTRS`, as
    `dart_library` does; the import check aspect skips it.
37. `import_check_validation` → `import_check_output_groups`, with the same
    arguments. It returns a dict for `OutputGroupInfo(**...)`: `_validation`,
    and `dart_unused_deps`, which the fixer reads. A rule that writes Dart
    files it compiles with the target's own, such as a test's bootstrap,
    passes them as `generated`. Their imports count as uses of `deps`. They
    aren't checked for what they import, since the rule wrote them.

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

rules_dart needs Bazel 9.0.0 or newer. Add this to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "<the latest release>")  # https://github.com/aran/rules_dart/releases
bazel_dep(name = "rules_dart_gazelle_plugin", version = "<the same version>")  # optional, see Gazelle

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.13.7")
use_repo(dart, "dart_toolchains")

register_toolchains("@dart_toolchains//:all")
```

Use the newest release, which you can find in the
[Bazel Central Registry](https://registry.bazel.build/modules/rules_dart). The
notes of each [GitHub release](https://github.com/aran/rules_dart/releases)
start with the exact `bazel_dep` lines. The two modules are released together,
from the same tag, so they always have the same version.

`dart_version` is the Dart SDK the build downloads and uses, exactly.

`rules_dart_gazelle_plugin` is optional. It is a separate module so that
rules_dart itself brings no Go dependency. Leave it out if you don't generate
BUILD files with [Gazelle](#build-file-generation-with-gazelle).

## Getting started

### Rules

A package's BUILD file goes at the package's root, the directory that holds
its `lib/`, `bin/` and `test/`. It declares the package's library, binaries and
tests. Gazelle can write it for you (see
[BUILD file generation with Gazelle](#build-file-generation-with-gazelle)).

```starlark
# greeter/BUILD.bazel
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

```shell
bazel build //greeter/...       # compile
bazel run //greeter:app         # run the binary
bazel test //greeter/...        # run the tests
```

A test that imports `package:test` also needs it in `deps`. See
[Using pub.dev packages](#using-pubdev-packages) and [Tests](#tests).

#### Package metadata

The BUILD file above is enough to build and run `greeter`, but the build rules
don't read `pubspec.yaml`. Without more information, rules_dart names the
package after its directory and compiles it at the language version of the SDK
you're using. That may be newer than the one your pubspec asks for. (The
pubspecs of packages you download from pub.dev are read for you. See
[Using pub.dev packages](#using-pubdev-packages).)

To tell the build what your pubspec says, declare a `dart_package_metadata` and
point each of the package's targets at it with `package`. Take a package laid
out like this:

```
greeter/
├── pubspec.yaml
├── LICENSE
├── hook/
│   └── build.dart
├── lib/
│   └── greeter.dart
└── test/
    └── greeter_test.dart
```

```yaml
# greeter/pubspec.yaml
name: greeter
version: 1.2.0
environment:
  sdk: ^3.11.0
dependencies:
  path: ^1.9.0
dev_dependencies:
  test: ^1.25.0
```

Its BUILD file states the same facts:

```starlark
# greeter/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "greeter",          # pubspec `name`
    language_version = "3.11",         # optional: lower bound of `environment.sdk`
    license_file = "LICENSE",          # optional
    build_hook = "hook/build.dart",    # optional
    code_assets = [":greeter_native"], # optional: the native code the hook would build
)

dart_code_asset(
    name = "greeter_native",
    asset_id = "package:greeter/greeter.dart",  # the id the `@Native` bindings use
    file = ":greeter_shared",                   # a cc_shared_library
)

dart_library(
    name = "greeter",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    deps = ["@pub_deps//:path"],       # pubspec `dependencies`
)

dart_test(
    name = "greeter_test",
    main = "test/greeter_test.dart",
    package = ":pubspec-metadata",
    deps = [
        ":greeter",
        "@pub_deps//:test",            # pubspec `dev_dependencies`
    ],
)
```

The pubspec's `version` has no counterpart. rules_dart records a version only
for packages pub resolved. Dependencies go on the targets that import them, not
on the metadata.

**rules_dart never runs a build hook.** A package with one must list in
`code_assets` or `data_assets` what the hook would have built. Without either,
every program that uses the package fails to build. See
[Native code assets](#native-code-assets) and [Data assets](#data-assets).

The test names the metadata too, because Dart applies the package's language
version to every file under the pubspec's directory, `test/` included.

Only `package_name` is required. The smallest declaration is:

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "greeter",
)
```

That gives the package its name, and nothing else. Its files compile at the
SDK's language version.

If you use Gazelle, it writes most of this for you. It generates the
metadata from `pubspec.yaml`, `hook/` and the license file, and names it
`pubspec-metadata`. You can give the target any name you like. If the root's
BUILD file already has a `dart_package_metadata`, Gazelle updates that one,
whatever it's called. It never writes `code_assets` or `data_assets`, so you
write those, and Gazelle keeps them. See [BUILD file generation with Gazelle](#build-file-generation-with-gazelle).

A package should have one `dart_package_metadata`. Suppose two targets of the
same package name different ones, or one names it and the other names none.
Then any program, test, library or analysis that reaches both fails to build,
and the error names both targets.

If you're used to other languages in Bazel, you might expect one library per
directory. Dart doesn't need that. Directories under `lib/` have no meaning to
the compiler, and files in one package may import each other in a cycle. So one
`dart_library` holding all of `lib/` is the usual layout, and it's the one
Gazelle writes.

You can still split a package over several BUILD files by hand. Put a BUILD
file in `lib/`, or in any directory under it. Its `dart_library` holds the files
next to it, and belongs to the package whose root is the directory above that
`lib/`. It names the same `dart_package_metadata` as the rest of the package,
so the metadata has to be visible to it:

```starlark
# greeter/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "greeter",
    visibility = [":__subpackages__"],
)

dart_library(
    name = "greeter",
    srcs = ["lib/greeter.dart"],
    package = ":pubspec-metadata",
    deps = ["//greeter/lib/src/model"],
)
```

```starlark
# greeter/lib/src/model/BUILD.bazel
# Holds package:greeter/src/model/model.dart.
dart_library(
    name = "model",
    srcs = ["model.dart"],
    package = "//greeter:pubspec-metadata",
)
```

Because every part names the one metadata, a program gets all of the package's
facts whichever part it reaches.

The parts are separate Bazel targets, with the limits that brings. Each part
depends on the parts its files import, relative imports included. So the parts
can't import each other in a cycle. A target outside the package depends on the
parts it imports.

Gazelle doesn't write this layout, and won't keep it. It removes the rules it
wrote from a BUILD file under `lib/`, and in fix mode deletes the file. If the
file holds anything Gazelle didn't write, Gazelle fails and names the file. See
[One library per package](#one-library-per-package).

rules_dart finds a package's root from the `lib` in its path. So a directory
named `lib` inside another `lib/` is an error, because the root is ambiguous.
`lib/src/lib/` is one example. A package whose root is somewhere under another
`lib/` is another. Rename the inner directory.

#### Your packages that import each other

Dart lets two packages import each other. Bazel doesn't let two targets depend
on each other. Say `ping` imports `pong` and `pong` imports `ping`. Put each
`dart_library` in the other's `deps` and Bazel fails with "cycle in dependency
graph". Leave one of those `deps` out and the import check fails instead. Its
message points you here.

The fix is to build the two packages as one target. Each package gets a
`dart_package_member` in its own BUILD file. The member holds the package's
`lib/` files and names its `dart_package_metadata`, if it has one. Then one
`dart_package_cycle` lists the members, with what they import from outside the
cycle in `deps`.

```starlark
# ping/BUILD.bazel
dart_package_member(
    name = "member",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    visibility = ["//:__pkg__"],
)

alias(
    name = "ping",
    actual = "//:ping_pong",
    visibility = ["//visibility:public"],
)
```

```starlark
# BUILD.bazel
dart_package_cycle(
    name = "ping_pong",
    members = [
        "//ping:member",
        "//pong:member",
    ],
    deps = ["@pub_deps//:collection"],
    visibility = ["//visibility:public"],
)
```

Binaries and tests depend on `//:ping_pong`. The `alias` keeps `//ping`
working too. Each package keeps its own name, root and language version.
Analysis, formatting, coverage and the import check treat each one as they
would a package built alone. A member isn't a library, so only its cycle can
depend on it.

Nothing is a cycle until you write one. Building the cycle checks that its
members are exactly one cycle. Suppose someone removes an import, and `pong`
no longer imports `ping`. The build then fails and says what to change. It
also fails when the cycle leaves out a package that is part of it, and names
that package.

What if your package and a pub package import each other? Your target can't be
in a cycle with a pub package, so your package has to join the pub build. List
it in `build_from_pubspec` of `pub.from_lock()` instead of `resolve` (see
[Using pub.dev packages](#using-pubdev-packages)), and it builds as a pub
package does. Then declare the cycle with `pub.cycle()`, as
[Packages that depend on each other](#packages-that-depend-on-each-other)
shows.

You don't have to spot such a cycle yourself. When a lock lists a `resolve`
package by a `path` inside its repository, the build reads that package's
`pubspec.yaml` to learn what it depends on. A cycle between it and pub packages
then fails when a pub package in it is first built. The error names every
package in the cycle, the one to move to `build_from_pubspec`, and the
`pub.cycle()` to add.

Gazelle can write these targets for you. Add a `dart_cycle` directive (see
[Directives](#directives)).

#### Deps match imports

A target's `deps` should be exactly what its files import. rules_dart checks
this in both directions, on every build.

An import that no dep provides fails the build. So does an import of a package
that only a dep's dep provides. Add the target that provides it to `deps`.

A dep that none of the target's files imports fails the build too. Such a dep
compiles nothing in. But a change to it still rebuilds the target and reruns
every test above it. The error names the target and each unused dep:

```
//app:app: no file imports or exports these deps:
  //net:client
  @deps//:path_provider
bazel run @rules_dart//dart/unused_deps -- //app:all removes them. One used without an import is exempt when its rule returns DartUsedWithoutImportInfo; features = ["-dart_unused_deps"] turns the check off.
```

The first line names the entry in your BUILD file that lists the deps. When a
macro made the target, that is the macro call. A `flutter_test` is named as
`//app:t`, not as the `//app:t.program` it makes. Each dep is spelled as your
BUILD file can write it: `:x` in the same package, `//pkg` when the name matches
the package's last component, and `@rules_dart//dart/runfiles` for another
module. A dep reached through an alias, such as `@deps//:path_provider` from a
pub hub, is printed with its canonical label. Bazel resolves the alias before
the rule sees it, so the rule has no name for it that your module knows.

Every file of the target counts, so a library's `src/` files count. So does
every branch of a conditional import, and an `export`. So does the package's
`hook/link.dart`, which is built from the package's deps. A test counts the
support files in its own `srcs`. It also counts the bootstrap the rule writes,
which imports `package:test`. So a test that gets `package:test` through a
helper library still lists it, and passes. If the support files are a library of their
own, that library carries their deps, and the test doesn't list them again.

Some deps do their work without an import. A Flutter plugin is registered by
native code, so the app lists it and never imports it. A plugin's rule marks
it as such, and the check leaves it alone wherever it's listed. A dep with no
Dart in it at all, such as a font, isn't checked either. Nor is a dep whose
package brings native code or data assets. A program uses those by asset id,
not by import. A dep you need only for its `resources`, files the program
reads by path at run time, goes in `data`, which puts them in its runfiles.

For any other dep you need without importing it, turn the check off for that
target with `features = ["-dart_unused_deps"]`. You can also turn it off for a
BUILD file with `package(features = ...)`, or for the whole build with
`--features=-dart_unused_deps`.

Gazelle writes `deps` from imports, so the BUILD files it writes pass.

To remove the unused deps, run the fixer:

```shell
bazel run @rules_dart//dart/unused_deps -- //...
bazel run @rules_dart//dart/unused_deps -- --dry-run //app:all
```

It takes the arguments of `@rules_dart//dart/format`: an optional `--dry-run`,
then `bazel build` flags and patterns. It finds the labels each entry wrote, so
it removes a dep written through an alias. It also edits the macro call that
made a target. When a macro gives one `deps` to several targets, such as a test
and its copy for another platform, a dep goes only if every one of them finds it
unused. `--dry-run` prints the `buildozer` commands and changes nothing.

The fixer formats every BUILD file it edits as buildifier does, so in a file not
already in buildifier's format the diff shows reordering beyond the removals.
Run buildifier over the files once first to keep that out of the fixer's diff.

The fixer cannot edit a dep that comes from a list variable (`deps = SHARED +
[...]`) or from a call inside a list comprehension. It prints the place in the
BUILD file and the entry for each dep it left, and exits 1, and `--dry-run`
reports the same deps and exits the same way. Remove those by
hand, unless something else that uses the list needs them. Gazelle users don't
need the fixer, as Gazelle writes `deps` from imports.

### Running the Dart SDK

To run the `dart` command of the SDK the toolchain pins:

```shell
bazel run @rules_dart//dart -- --version
```

It runs in the directory you ran `bazel run` from, so relative paths work as
usual. Like every build action, it runs with Dart's analytics turned off, so it
writes no analytics files to your home directory.

Use it for commands that don't need package resolution. **Don't use it to
analyze, format or test.** `dart analyze` would report errors that the build
doesn't have. Bazel builds packages without writing a
`.dart_tool/package_config.json`, and generated files exist only under
`bazel-bin`. So `dart analyze` can't resolve their imports or find the members
that generated code adds. Bazel has its own commands for those jobs, listed in
the [command map](#command-map).

To write or update a `pubspec.lock` with the same SDK, run pub through Bazel:

```shell
bazel run @rules_dart//dart/pub -- get
bazel run @rules_dart//dart/pub -- upgrade --directory=app path
```

This one runs at the workspace root, so `--directory` is relative to the
workspace root. Any pub subcommand works. It needs only the Dart toolchain, so
it still works when `pub.from_lock()` refuses your lock. That is when the
refusal's error message tells you to run it.

> **Tip**: Consider using [`bazel_env`](https://github.com/buildbuddy-io/bazel_env.bzl)
> to put the Bazel-managed binaries, the pinned `dart` among them, on your `PATH`
> for IDE and shell use.

### Command map

Dart's documentation, and the tools and coding agents that follow it, assume a
system-wide Dart install and a package that `pub get` has resolved on disk. A
rules_dart workspace has neither (see
[Running the Dart SDK](#running-the-dart-sdk)). This table gives the Bazel
command to run instead, where there is one. `<dir>` is a package's directory
relative to the workspace root.

| Dart command | In a rules_dart workspace |
| --- | --- |
| `dart pub add foo`, `remove`, `get`, `upgrade`, `outdated`, `deps` | `bazel run @rules_dart//dart/pub -- add foo --directory=<dir>`. Any pub subcommand works. It runs the pinned SDK at the workspace root. The build takes its packages and versions from `pubspec.lock`, so an edit to `pubspec.yaml` changes nothing until pub re-resolves. After `add`, run Gazelle. See [Adding a dependency](#adding-a-dependency). |
| `dart analyze` (`--fatal-infos`) | `bazel test //<dir>/...`, once the `dart_analyze` aspect lines are in `.bazelrc`. Every diagnostic fails it, infos included. `bazel build` does not analyze. See [Static analysis and formatting](#static-analysis-and-formatting). |
| `dart format` | The same `bazel test` checks formatting, as the `dart_format` output group. To rewrite files, run `bazel run @rules_dart//dart/format -- //<dir>/...`. It takes the same flags and target patterns as `bazel build`. |
| `dart fix --dry-run` / `--apply` | `bazel run @rules_dart//dart/fix -- --dry-run //<dir>/...` / `bazel run @rules_dart//dart/fix -- //<dir>/...`. See [Formatting and fixing](#formatting-and-fixing). |
| `dart test` | `bazel test //<dir>:<name>`, or `//<dir>/...`. Its flags are in the next table. |
| `dart run build_runner build` / `watch` | None. Don't run `build_runner`. The build generates the code itself, under `bazel-bin` at the source file's path. See [Code generation](#code-generation). |
| `dart run bin/app.dart` | `bazel run //<dir>:app`, a `dart_binary`. |
| `dart compile exe` / `aot-snapshot` / `kernel` | `dart_binary(compile_mode = ...)`. The default is `exe`. |
| `dart compile js` / `wasm` | `dart_js_binary` / `dart_wasm_binary`. See [Web compilation](#web-compilation). |
| `dart doc` | None. |
| `dart run coverage:test_with_coverage`, `dart test --coverage` | `bazel coverage --combined_report=lcov //<dir>/...`. It writes one LCOV report for all the tests it runs. See [Coverage](#coverage). |

`dart test`'s options have these counterparts:

| `dart test` | `bazel test` |
| --- | --- |
| `--name`, `-n` | `--test_filter=<regex>`. The runner passes it on as `--name`, so it is a regular expression. It selects cases within the targets you name, so `bazel test //<dir>:<name> --test_filter=...` runs one case. |
| `--plain-name`, `-N` | None. Escape the regex metacharacters in `--test_filter`. |
| `--tags`, `-t`, `--exclude-tags`, `-x` | The target's `include_tags` / `exclude_tags`. For one run, `--test_env=DART_TEST_TAGS=<selector>` / `DART_TEST_EXCLUDE_TAGS`. A file's `@Tags` also select whole targets through `--test_tag_filters`. See [Tests](#tests). |
| `--test-randomize-ordering-seed` | `--test_env=DART_TEST_ORDERING_SEED=<seed>`, where the seed is an unsigned 32-bit integer or `random`. See [Tests](#tests). |
| `--shard-index`, `--total-shards` | `shard_count`. |
| `--timeout` | The target's `size` or `timeout`. |
| `--concurrency`, `-j` | Bazel runs targets in parallel (`--local_test_jobs`). A target's cases run in one runner. |
| `--reporter`, `--file-reporter`, other runner flags | No pass-through. Cases appear in Bazel's report (`test.xml`). `--test_output=errors` or `all` shows the runner's output. |

The build doesn't read `dart_test.yaml`. Each of its settings has a place on the
`dart_test` target or in Bazel (see [Tests](#tests)).

It doesn't read `build.yaml` either. A builder's options go in its macro's
`config`, or in a `# gazelle:dart_builder_config` directive (see
[Directives](#directives)). The macro's `srcs` choose the files the builder runs
on (see [`docs/ext.md`](./docs/ext.md)). Gazelle copies a builder's `options`
from `build.yaml` into `config` for you, and fails on anything else in the file
(see [build.yaml](#buildyaml)).

Your editor's analysis server reads `.dart_tool/package_config.json`, and so do
`dart mcp-server`'s `analyze_files` and `run_tests`. Only `pub get` writes that
file. It knows nothing of the packages Bazel builds or the files generated in
`bazel-bin`. So these tools report unresolved imports and undefined generated
members that `bazel test` doesn't. Don't quiet them by adding those packages to
`pubspec.yaml` or by writing the generated files by hand. Run `bazel test`,
which is the analyzer that counts here.

### Working with coding agents

A coding agent learned Dart from documentation that assumes a system `dart`, a
package resolved by `pub get`, and `build_runner`. Tell it what's different here
in the repository's `AGENTS.md` (or `CLAUDE.md`). Change the Gazelle target
(`//:gazelle`) if yours has another name.

```markdown
- This workspace is built by Bazel with a hermetic Dart SDK. Never run `dart`,
  `pub` or `build_runner` from a system install. Run the pinned SDK as
  `bazel run @rules_dart//dart -- <args>` and pub as
  `bazel run @rules_dart//dart/pub -- <args> --directory=<dir>`.
- `bazel test //<dir>/...` is the analyzer and the format check. It fails on
  every diagnostic, infos included, and on any file `dart format` would change.
  `bazel build` checks neither. Run `bazel test` before finishing.
- `bazel run @rules_dart//dart/fix -- //<dir>/...` applies the analyzer's fixes,
  and `bazel run @rules_dart//dart/format -- //<dir>/...` formats. Both take
  `bazel build` target patterns, not file paths.
- Never run `build_runner`, and never write or commit generated code. The build
  generates it, under `bazel-bin` at the source file's path.
- After adding, removing or renaming a Dart file or an import, run
  `bazel run //:gazelle`, which rewrites `BUILD.bazel` files. Run it again after
  `bazel run @rules_dart//dart/pub -- add <package> --directory=<dir>`, so that
  `package:<package>` imports get their `deps`.
- The build reads neither `build.yaml` nor `dart_test.yaml`. Gazelle copies a
  builder's `build.yaml` options into its codegen target's `config`. A test's
  tags, timeout, retries and shards go on its `dart_test` target.
- An editor or `dart mcp-server` may report unresolved imports or missing
  generated members. These are not errors in the build. Do not edit
  `pubspec.yaml` to quiet them.
```

## Using pub.dev packages

rules_dart brings in packages from pub in two ways. `pub.from_lock()` imports
every package a `pubspec.lock` names, which suits most projects with a
`pubspec.yaml`. `pub.package()` declares one package at a time.

To use a lock:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
)
use_repo(pub, "pub_deps")
```

This makes a hub repository, `pub_deps`, with a target for every package the
lock names. Depend on them by package name:

```starlark
dart_binary(
    name = "app",
    main = "bin/main.dart",
    deps = [
        "@pub_deps//:path",
        "@pub_deps//:collection",
    ],
)
```

Each package is downloaded into its own repository, and only when something
builds it. That makes caching finer and lets downloads run in parallel. Bazel
checks each archive against the `sha256` the lock records. A lock written by a
pub older than 2.19 has no `sha256` and is refused. Re-resolve it with
`bazel run @rules_dart//dart/pub -- get --directory=<its directory>`.

**The hub's name is shared across the whole build.** It isn't scoped to your
module. If two modules both call `pub.from_lock(name = "pub_deps", ...)`, they
get one hub holding the packages of both locks. That lets you import a package
that only another module's lock names. It works until that module leaves the
build, so list everything you import in your own lock.

To declare a single package instead:

```starlark
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.package(
    name = "path",
    version = "1.9.1",
    sha256 = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5",
)
use_repo(pub, "path")
```

Its target is named after the package:

```starlark
dart_binary(
    name = "app",
    main = "bin/main.dart",
    deps = ["@path//:path"],
)
```

`version` is the lowest version you accept, and the build may choose a newer
one. `sha256` is the digest of the package's archive (see
[The sha256 of a `pub.package()`](#the-sha256-of-a-pubpackage)). You can use
both tags in one build. A package you declare with `pub.package()` is still in
the hub of any lock that lists it. Either label builds the one version the
whole build chooses (see [Versions](#versions)).

A package is built against the dependencies its own pubspec names. Each one has
to come from another `pub.package()` or from a lock. If one is missing, the
fetch fails and the error names both packages.

rules_dart reads each package's `pubspec.yaml` the way pub does, with Dart's
`package:yaml`. The reader is a small program that rules_dart compiles once per
host, with your Dart SDK. If pub would refuse a pubspec, for example one with an
`sdk:` constraint written as a number, the fetch fails with pub's message and
names the package. Your own repository rules can read pubspecs the same way
(see [Reading a pubspec](#reading-a-pubspec)).

### Git and SDK packages

`pub.from_lock()` fetches **hosted** packages, from pub.dev or another
registry, and **git** packages. It skips **sdk** packages, and needs to be told
what to do with **path** packages (see
[Local packages and forks](#local-packages-and-forks)).

A git package is fetched at the commit the lock records as `resolved-ref`. That
must be a full 40-character commit id. The package is taken from the lock's
`path` within the git repository.

The fetch uses your host's `git`, which must be 2.14 or newer, as for
`dart pub get`. It sees your git configuration and the environment variables
that carry configuration: `GIT_SSH_COMMAND`, `GIT_ASKPASS`,
`GIT_TERMINAL_PROMPT`, `GIT_CONFIG_COUNT` with its keys and values, and
`GIT_CONFIG_PARAMETERS`. So credential helpers and `insteadOf` mirrors work. The
`GIT_*` variables that tell git where a repository is are unset, so they can't
send the fetch into your own checkout.

Writing out the files uses none of your git configuration and none of your
`GIT_*` variables. There is no line-ending conversion, and none of your filters
or hooks run. The repository's own `.gitattributes` do apply, as they do for
pub. So every machine gets the same bytes.

Some servers won't fetch a commit by its id. rules_dart then asks for every ref
the server advertises, as pub does.

Two locks that pin one git package at different commits fail. So does a
package that is git in one lock and hosted in another.

Packages with an `sdk` source, such as Flutter's, come with an SDK, not from
pub. rules_dart skips them and makes no repository for them. A `package:`
import of one fails to resolve unless something else provides the package, such
as a target you map with `resolve`. (Flutter's come from rules_flutter's pub
extension.) Each `pub.from_lock()` prints one message listing the sdk packages
it skipped. If a fetched package depends on a skipped one, it fails when it is
fetched, and the error names the dependency. It is never built without it.

### Local packages and forks

A lock also lists the `path` packages your pubspec depends on. rules_dart
doesn't guess how to build them. You name each one in exactly one of three
attributes of `pub.from_lock()`: `resolve`, `build_from_pubspec` or `ignored`.
A `path` package left out fails when the lock is read, and so does a name the
lock doesn't list.

`resolve` serves a package from a target of yours. Use it for a local package
that has its own BUILD files. It works for a hosted, git or sdk package too, to
build a fork, say:

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    resolve = {
        "my_shared_models": "//shared_models",  # a `path` package: must be named
        "http": "//third_party/http_fork",      # a hosted package: replaced
    },
)
```

The target stands in for that package across the whole build.
`@pub_deps//:http` becomes an alias of it, and every locked package that
depends on `http` gets it instead. The target must build a package of that
name, meaning the `package_name` of its `dart_package_metadata` must be `http`.
That is checked when the target is analyzed. The lock's version of the package
is not. The target must also be visible to the extension's repositories, so
give it `//visibility:public`.

Gazelle resolves `package:http` imports to `@pub_deps//:http`, which leads to
the mapped target. So you don't need a `# gazelle:resolve` directive for it.

Two `pub.from_lock()` calls that map one package to different targets fail.
So does mapping a package that is also declared with `pub.package()`.

`build_from_pubspec` is for a local package with no BUILD files. rules_dart
builds it from its directory, the way it builds a hosted package from its
archive. The directory is the lock's `path`, resolved against the lock's own
directory. The build sees only the package's `pubspec.yaml`, `lib/`, `hook/` and
license file, and an edit to any of them reaches the next build. Other files,
such as `.dart_tool/` and `build/`, are left out, so output from pub or your IDE
changes nothing. A package with a `BUILD` file anywhere in those parts is
refused. Map it with `resolve` instead.

`ignored` is for a `path` package that nothing in the build uses, such as one
only your editor or a pub-side tool reads. You give a reason. The package still
has a hub label, but anything that depends on it fails at analysis, with your
reason in the error.

```starlark
pub.from_lock(
    name = "pub_deps",
    lock = "//:pubspec.lock",
    build_from_pubspec = ["local_greeting"],
    ignored = {"editor_only": "only the editor reads it"},
)
```

For `build_from_pubspec`, the lock has to name the directory by a relative
path. `dart pub get` writes one when the pubspec's `path:` is relative. The
directory must also be inside the repository that holds the lock. An absolute
path, or one leading out of the repository, would work on only one machine, so
it fails when the lock is read. Map such a package with `resolve` instead.

If two locks both build one package from its pubspec, they must name the same
directory. A package built from its pubspec in one lock and fetched or ignored
in another fails too.

### Packages that depend on each other

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

For packages of your own workspace that import each other, see
[Your packages that import each other](#your-packages-that-import-each-other).

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
[`dart/ext/registry.bzl`](dart/ext/registry.bzl):

| Packages                 | Why                                                           |
| ------------------------ | ------------------------------------------------------------- |
| `dio`, `dio_web_adapter` | `dio` exports the web adapter on the web, which imports `dio` |

### Versions

rules_dart builds one version of each package for the whole build. Each place
that states a hosted package's version makes a request. That means every
`pub.package()`, in any module, and every lock that lists the package. The
build takes the highest request, the way Bazel's minimal version selection
treats a `bazel_dep`. A `pub.package()` that asked for a lower version keeps its
`@name` repository, which builds the chosen version. Two requests for the same
version must give the same sha256.

Each request is a minimum. So a module you depend on can ask for more than your
root module does, and the build takes the higher version. It then reports that
it raised the root's request, much as Bazel's `--check_direct_dependencies` does
for a `bazel_dep`:

```text
Package "tuple" is built at 2.0.2, newer than the root module asks for:
  - 2.0.1, from the lock `//:pubspec.lock`
Raised by:
  - 2.0.2, from `pub.package()` in module `dep_mod`
Each request is a minimum and the highest wins. Raise the root's to 2.0.2:
  bazel run @rules_dart//dart/pub -- upgrade tuple
or set `pub.settings(check_direct_dependencies = "off")` in the root module to stop this check.
```

The root module chooses how this is reported:

```starlark
pub.settings(check_direct_dependencies = "error")  # "off", "warning" (the default) or "error"
```

Only the root's own requests are checked. When the root or another dependency
raises a dependency's request, nothing is reported, as in Bazel.

Only hosted packages have a version order. If the root's lock lists a package
as `git`, `sdk` or `path`, the whole build uses what that lock says, over any
other module's `pub.package()` or lock entry for it. This works like a root
`git_override` taking precedence over a `bazel_dep`.

Only the root module may use `pub.settings`, `ignore_hooks` or `ignore_hook`.

The Dart SDK version isn't a request. The root's `dart.toolchain` version is
used exactly, and a module asking for a newer SDK fails the build, with an error
that names the fix. To take the highest request instead, the root sets
`allow_upgrade_by_dependencies = True` on its `dart.toolchain`.

### Adding a dependency

pub chooses versions and records them in `pubspec.lock`. Bazel builds exactly
what the lock records. So adding a package takes three steps:

```shell
bazel run @rules_dart//dart/pub -- add foo --directory=app   # edits app/pubspec.yaml and app/pubspec.lock
bazel run //:gazelle                                          # puts @pub_deps//:foo in the deps that import it
bazel build //app/...
```

1. `pub add` runs the pinned SDK at the workspace root. `--directory` names the
   package whose `pubspec.yaml` you're changing. It must be the directory whose
   `pubspec.lock` your `pub.from_lock()` reads. pub's usual forms work:
   `add dev:foo`, `add foo:^1.2.0`, `remove foo`. You can also edit a
   constraint in `pubspec.yaml` by hand and then run `pub get` (or
   `pub upgrade foo`). The build takes versions only from the lock, so until
   pub re-resolves, the edit changes nothing.
2. Import the package in your source, then run Gazelle. It resolves
   `package:foo/...` to `@pub_deps//:foo`, in the hub that
   `# gazelle:dart_pub_deps_repo` names. Without Gazelle, add `@pub_deps//:foo`
   to the `deps` of each target that imports it.
3. Build. If the error says `@pub_deps//:foo` doesn't exist, the lock doesn't
   list `foo`. Step 1 hasn't run for that lock.

`use_repo(pub, "pub_deps")` stays as it is, because the one hub holds every
package the lock names.

A workspace with only `pub.package()` declarations, and no `pubspec.yaml`, has
nothing for `pub add` to edit. Add the declaration by hand, with the digest
described next.

### The sha256 of a `pub.package()`

`pub.package()` needs the sha256 of the package's archive, which Bazel checks
when it downloads it. Write it as `pubspec.lock` does, as 64 lowercase hex
digits. pub.dev's API gives it as `archive_sha256`:

```shell
curl -s https://pub.dev/api/packages/path/versions/1.9.1 | jq -r .archive_sha256
```

If the package is already in a `pubspec.lock`, you can copy the `sha256:` under
its `description` instead. A digest in any other form fails when `pub.package()`
is read, and the error names the package.

### Package identity and SBOMs

Every repository the `pub` extension fetches says what it holds, in Bazel's
supply-chain metadata
([`package_metadata`](https://github.com/bazel-contrib/supply-chain)).
rules_python's pip and Gazelle's `go_repository` do the same. Each repository
has a `package_metadata` target with the package's purl, and its `REPO.bazel`
attaches that target to every target in the repository. An SBOM tool's aspect
reads it from each target's `package_metadata` attribute.

| Source | purl |
|---|---|
| hosted (`pub.package()`, `pub.from_lock()`) | `pkg:pub/<name>@<version>?checksum=sha256:<hex>`, with `repository_url` for a registry other than pub.dev |
| git | `pkg:pub/<name>@<version>?vcs_url=git+<url>@<commit>`, with `#<path>` for a package in a subdirectory |
| path, `build_from_pubspec` | None. The package is yours, and states its own. |

The Dart SDK's repositories are `pkg:generic/dart-sdk@<version>`, with the
archive's `checksum` and `download_url`. The purl spec has no type for the SDK.

Where rules_dart builds native code in place of a package's build hook, that
code is identified by what it's built from. `//dart/ext/sqlite3` is identified
as the BCR `sqlite3` module, and the BoringSSL that webcrypto vendors as
BoringSSL.

None of these carries a `license`, because no pub package states its license
kind. pub.dev works it out on its own servers. The license text is still there,
as the `license_file` of the package's `dart_package_metadata`.

## BUILD file generation with Gazelle

rules_dart has a [Gazelle](https://github.com/bazelbuild/bazel-gazelle) plugin
that writes your `BUILD.bazel` files for you. It reads your Dart sources, their
imports and each package's `pubspec.yaml`. The plugin is a module of its own,
`rules_dart_gazelle_plugin` (see [Installation](#installation)). Add Gazelle
itself beside it in `MODULE.bazel`:

```starlark
bazel_dep(name = "gazelle", version = "0.54.0")
```

Then define a Gazelle binary with the Dart plugin, and a target that runs it, in
the root `BUILD.bazel`:

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

If your pub.dev packages come from `pub.from_lock(name = "pub_deps", ...)`, tell
Gazelle so with a directive in the same file:

```starlark
# gazelle:dart_pub_deps_repo pub_deps
```

Without it, an import of `package:path/path.dart` resolves to `@path`, the
repository that `pub.package(name = "path", ...)` creates.

Run Gazelle whenever you add files or change imports:

```shell
bazel run //:gazelle
```

Take a package laid out like this, where `lib/greeter.dart` imports
`package:path`:

```
greeter/
├── pubspec.yaml
├── bin/
│   └── greet.dart
├── lib/
│   ├── greeter.dart
│   └── src/
│       └── format.dart
└── test/
    ├── fixtures.dart
    └── greeter_test.dart
```

Gazelle writes a BUILD file in `greeter/`, `greeter/bin/` and `greeter/test/`.
The one at the package's root holds the package's metadata and its library:

```starlark
# greeter/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "greeter",
    language_version = "3.11",
    visibility = ["//greeter:__subpackages__"],
)

dart_library(
    name = "greeter",
    srcs = [
        "lib/greeter.dart",
        "lib/src/format.dart",
    ],
    package = ":pubspec-metadata",
    visibility = ["//visibility:public"],
    deps = ["@pub_deps//:path"],
)
```

`bin/greet.dart` becomes a `dart_binary` named `greet` in `greeter/bin/`. The test
directory gets a `dart_test` for the `_test.dart` file. `fixtures.dart` is a
helper the test imports, so it goes in the test's `srcs`:

```starlark
# greeter/test/BUILD.bazel
dart_test(
    name = "greeter_test",
    srcs = ["fixtures.dart"],
    main = "greeter_test.dart",
    package = "//greeter:pubspec-metadata",
    deps = [
        "//greeter",
        "@pub_deps//:test",
    ],
)
```

In general, Gazelle treats each directory of a package as `dart` and `pub`
would:

- **`lib/`**: every file goes into the package's one `dart_library` (see
  [One library per package](#one-library-per-package)).
- **`bin/`**: each file becomes a `dart_binary`.
- **`test/`**: each `_test.dart` file becomes a `dart_test`, and the other files
  are helpers (below).
- **Any other directory**, such as `tool/`, `example/` or `benchmark/`: its
  files are scripts (below).

Gazelle fills in `deps` from each file's `import` and `export` directives,
including every URI of a conditional import. Modifiers such as `deferred as`,
`show` and `hide` don't change what is imported.

A package's root is the directory holding its `pubspec.yaml`. A directory whose
BUILD file has a `dart_package_metadata` is a root too, pubspec or not. Every
directory below the root is in that package, `tool/`, `example/` and
`benchmark/` included, and every rule Gazelle writes there names the package's
metadata. That stops at a directory below with a pubspec of its own, such as an
`example/` that is a separate package. As with `pub`, that directory is the root
of a new package. A package with neither a pubspec nor metadata has its root at
the directory above its `lib/`, `bin/` and `test/`, where `dart_library`
places it.

Scripts are the files you'd run with `dart run tool/release.dart`. Each file
with a top-level `main` becomes a `dart_binary`. Its `srcs` hold the files beside
it that it imports, directly or through each other. A file with no `main` that
no script beside it imports fails the run. So does a directory named `lib`
below the root that isn't the package's own `lib/` (`tool/lib/`, say), unless a
pubspec makes it a package of its own. A script whose binary would take the
library's name fails too, and the error asks you to rename the file.

Gazelle treats `test/` as `package:test` does. It makes a test of each
`_test.dart` file, and any other file there is a helper. A helper goes in the
`srcs` of every test that imports it, directly or through another helper. What
the helper imports goes in that test's `deps`. A test lists a helper in its own
directory by file name. When tests import helpers from another directory under
`test/`, Gazelle gives that directory a `filegroup` named after it, holding its
helpers, and the tests list the filegroup. That filegroup is visible to the
package's whole `test/` tree. It also holds any test file that a file elsewhere
imports.

When a run finds problems like these, Gazelle reports every one of them and
then fails, before it writes any BUILD file.

### One library per package

Gazelle writes each package as a single `dart_library`. It sits in the BUILD
file at the package's root, takes the package's name, and holds every file under
`lib/`. That is also how `pub.from_lock()` builds a package from pub.dev (see
[Package metadata](#package-metadata)).

Sources that carry a builder's annotation are in that library too, along with
what their builders generate. build_runner works the same way: it writes a
`.g.dart` beside its source, as a part of the same library. Gazelle gives each
annotated source codegen targets (see [Code generation](#code-generation)),
named after its path under `lib/` without `.dart`. For
`lib/src/model/user.dart` with a single builder, the target is
`src/model/user_codegen`. The library lists the codegen outputs in its `srcs`.
Plain and annotated sources may import each other.

A generated file can already sit in the source tree, as a published package
ships it. If one of those codegen targets produces it, Gazelle leaves the file
out of every `srcs`. Every other file is a source, whatever its name. A
`.g.dart` that no codegen target produces is an ordinary source.

You can't keep a BUILD file under `lib/` with Gazelle. Bazel would end the
library's sources at that directory, so the files below it would drop out of the
package's library. The rules do accept a package split into several libraries
this way, but you write and maintain that layout by hand, without Gazelle (see
[Package metadata](#package-metadata)).

When Gazelle finds a BUILD file under `lib/` that holds only rules it wrote, it
removes the rules, and in its default fix mode deletes the file. In
`-mode=diff` or `-mode=print`, which write nothing, that file fails the run
instead. A BUILD file there holding anything Gazelle didn't write always fails
the run: another rule, a directive, or an attribute Gazelle doesn't manage or
that is marked `# keep`. The error names the file and asks you to move what it
holds to the package's root.

Gazelle resolves an import to the rule that lists the imported file, whether
the import is a `package:` URI or a relative path. It falls back to the
package's name only for a file that no rule lists by name: a pub package's
file, or one matched by a `glob`. If two rules list the same file, Gazelle logs
it and adds neither. A `# gazelle:resolve dart package:<pkg>/<path> <label>`
directive picks one.

### Directives

Directives are comments in a `BUILD.bazel` file. Each applies to its directory
and the directories below it. Most projects need only `dart_pub_deps_repo`,
because Gazelle reads the rest from `pubspec.yaml` and `build.yaml`.

- **`# gazelle:dart_pub_deps_repo pub_deps`**: the repository that holds your
  pub.dev packages. With this one, `package:shelf/shelf.dart` resolves to
  `@pub_deps//:shelf`. Without it, it resolves to `@shelf`.

- **`# gazelle:dart_package_name my_app`**: the package's name, for a package
  with no `pubspec.yaml` or one that doesn't state it. Gazelle writes it as the
  `package_name` of the package's `dart_package_metadata`.

- **`# gazelle:dart_language_version 3.13`**: the package's language version,
  in the same cases. Gazelle writes it as the metadata's `language_version`.

  These two describe one package. They hold in the BUILD file's directory and
  below, up to the root of another package (a directory with its own
  `pubspec.yaml` or `dart_package_metadata`). That package states its own, as
  each package's pubspec does for `pub`.

- **`# gazelle:dart_cycle ping pong`**: `ping` and `pong` import each other,
  so they build as one target (see
  [Your packages that import each other](#your-packages-that-import-each-other)).
  Put it in a BUILD file above both packages. Gazelle writes a
  `dart_package_member` and an `alias` at each package's root. It writes the
  `dart_package_cycle`, named `ping_pong`, beside the directive. Imports of
  either package resolve to the cycle.

  Gazelle finds cycles itself, from what the packages import. If it finds one
  with no directive, the run fails. The error names the packages, a path
  through them, and the directive to add. A directive that no longer names
  exactly one cycle fails the run too, and the error says what to change. Take
  the directive out and Gazelle writes each package's `dart_library` again.

- **`# gazelle:dart_build_yaml_ignore targets.$default.builders.json_serializable.generate_for`**:
  a part of the `build.yaml` beside this BUILD file that the build does without
  (see [build.yaml](#buildyaml)).

- **`# gazelle:dart_builder_config JsonSerializable {"field_rename": "snake"}`**:
  options for the builder of an annotation, for a package with no
  `build.yaml`. The value is the JSON object that `build.yaml`'s `options:`
  would hand the builder. Gazelle writes it into the `config` of that builder's
  codegen targets, in this directory and below. If the package's `build.yaml`
  states different options, the run fails and names both.

- **`# gazelle:dart_builder_runtime_dep JsonSerializable //third_party:json_annotation`**:
  the library of an annotation's runtime package, if you use a fork of it. The
  label replaces that package in the `deps` of the package's library and of the
  builder's codegen targets.

- **`# gazelle:dart_builder <Annotation> macro=<file>%<symbol> shim=<label> ...`**:
  registers a builder that another module ships, so that Gazelle writes its
  targets. It goes only in the BUILD file at the repository's root.

  [`docs/ext.md`](docs/ext.md#directives) describes these last three fully.

- **`# gazelle:resolve dart foo //third_party:foo`**: Gazelle's own override,
  mapping the Dart package `foo` (the `foo` of `package:foo/...` imports) to an
  explicit Bazel target.

### pubspec.yaml and the package's metadata

Gazelle states a package's facts once, on one `dart_package_metadata` named
`pubspec-metadata` in the BUILD file at the package's root. Every rule it writes
for the package names it with `package`. That includes the library and codegen
targets, and the binaries and tests in every directory of the package
(`package = "//greeter:pubspec-metadata"`). Gazelle fills in:

- `package_name` from the pubspec's `name`, and `language_version` from the
  lower bound of its `environment.sdk`. The directives above supply them where
  the pubspec doesn't, so most projects need no directives.
- `build_hook` and `link_hook`, the package's hooks (see [Hooks](#hooks)).
- `license_file`: the root's `NOTICES` file, or else its `LICENSE`, by exact
  name. `pub.from_lock()` chooses the same way.

A package doesn't need a `pubspec.yaml`. If nothing states any of these facts,
Gazelle writes no metadata, and the package's rules name none. The rules then
name the package after its root directory. The repository's root has no
directory name, so a package there with codegen targets gets metadata stating
its library's name.

**Gazelle owns these five attributes. Each run rewrites them from
`pubspec.yaml`, the directives and the package's files. Mark one `# keep` to
make it yours.**

If the root's BUILD file already has a `dart_package_metadata`, Gazelle uses
it, whatever it is named. It merges its attributes in and keeps the ones it
doesn't write: `code_assets`, `data_assets`, `link_hook_assets`,
`linked_code_assets` and `version`. A root BUILD file with two of them fails the
run. Metadata with no `pubspec.yaml` and no directive beside it is itself the
source of the package's name and language version, and Gazelle leaves those
alone.

A fact can be stated in up to three places: a `# keep` attribute, a directive
and the pubspec. They must agree. When two state the package's name or
language version differently, Gazelle reports each disagreement, with both
values and where each is stated, and fails without writing any BUILD file.

The facts belong on the metadata alone. Gazelle removes `package_name`,
`language_version`, `build_hook`, `link_hook` and `license_file` from the
package's other rules, and moves a library's `code_assets` onto the metadata.

### build.yaml

build_runner reads builder options from the `build.yaml` at a package's root.
For a package Gazelle writes codegen for, Gazelle reads that file too. Each
bundled builder's `targets.$default.builders.<builder>.options` goes into the
`config` of the targets Gazelle writes for that builder, as the JSON object
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

Builders are named as build_runner names them: `<package>:<builder>` (or the
older `<package>|<builder>`), or a bare `<package>` for the builder of that name.
[`docs/ext.md`](docs/ext.md#buildyaml) lists the bundled builders' names. A
builder from another module is named by the `key` of its `# gazelle:dart_builder`
directive. Options for a builder that no source of the package uses have no
target to go into.

The rest of the file has no place in a Bazel build. In Bazel, a codegen
target's `srcs` choose the files it runs on. So Gazelle can't carry over:

- any target other than `$default`
- a target's `sources`
- a builder's `generate_for`, `enabled`, `dev_options` or `release_options`
- `global_options`
- a builder Gazelle knows no name for

Gazelle names every such part, by its key path and line, and fails without
writing any BUILD file:

```
gazelle: dart: build.yaml:9: `targets.$default.builders.json_serializable.generate_for` is not carried into the build: ...; to build without it, add `# gazelle:dart_build_yaml_ignore targets.$default.builders.json_serializable.generate_for` to the BUILD file in .
```

To build without such a part, add `# gazelle:dart_build_yaml_ignore <key path>`
for it to the BUILD file beside the `build.yaml`, one directive per part.
Gazelle then carries over the rest. An ignore that names no part of that file
fails the run, and so does one stated twice.

If a package keeps its `build.yaml` for build_runner alone, add
`# gazelle:exclude build.yaml` to its root's BUILD file, and Gazelle won't read
it at all. build_runner reads a `build.<name>.yaml` only with `--config <name>`.
Gazelle fails the run on one until you exclude it the same way.

A `# gazelle:dart_builder_config` directive that states different options for
the same builder is a disagreement, as for the package's name (see
[Directives](#directives)).

### Hooks

A package's `hook/build.dart` is its build hook, and `hook/link.dart` its link
hook. Gazelle puts each in a `filegroup` in `hook/` (named `build` and `link`)
and names them as the `build_hook` and `link_hook` of the package's
`dart_package_metadata`. It writes nothing else for `hook/`.

rules_dart never runs a build hook. A package with one fails every binary and
test that reaches it, until its metadata's `code_assets` and `data_assets`
supply what the hook would build (see [Native code assets](#native-code-assets)
and [Data assets](#data-assets)). You write those two attributes yourself.
Gazelle never writes or removes them.

A link hook's imports go in the `deps` of the package's library, so that a
linked program can run it (see
[Recorded uses and link hooks](#recorded-uses-and-link-hooks)).

If your build uses nothing a hook provides, hide the hook from Gazelle with
`# gazelle:exclude hook/build.dart` (or `hook/link.dart`) in the package root's
BUILD file.

### Test tags

A test file's suite-level `package:test` tags become its `dart_test`'s Bazel
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

Bazel's own tag filters can then select whole test files:

```shell
bazel test //... --test_tag_filters=-slow          # skip slow files
bazel test //... --test_tag_filters=integration    # only integration files
```

Gazelle reads `@Tags` where `package:test` does: on the file's first directive
(`library`, `import`, `export` or `part`). It may be bare or import-prefixed
(`@t.Tags([...])`). Tags on individual tests and groups
(`test(..., tags: ...)`) stay with `package:test` (see [Tests](#tests)).

In two cases Gazelle warns instead of copying a tag. One is an annotation that
isn't a list of string literals, such as a `const` variable. The other is a tag
that means something to Bazel, since copying it would change how the test runs:
`manual`, `exclusive`, `exclusive-if-local`, `external`, `local`,
`block-network`, and any tag starting `no-`, `requires-`, `supports-` or
`disable-`.

Gazelle manages a `dart_test`'s `tags`. A tag you remove from `@Tags` leaves the
target on the next run. A tag you add by hand stays only if you mark it
`# keep`, as with every attribute Gazelle manages. Gazelle logs each tag it
removes.

```starlark
    tags = [
        "exclusive",  # keep
        "slow",
    ],
```

### Test platforms

`dart test` on a file whose `@TestOn` excludes the current platform finds no
tests, and fails. Under Bazel the test should be skipped instead. So Gazelle
turns a test file's `@TestOn` into its `dart_test`'s `target_compatible_with`:

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

Gazelle evaluates the selector as `package:test` does, over the platforms a
`dart_test` can be built for. Those are the Dart VM on Linux, macOS, Windows or
another OS, and the two web platforms. A web platform carries the
`@rules_dart//dart/constraints:runtime` value `js` or `wasm` and, as a browser
has for `package:test`, no OS.

Gazelle understands `vm` (and `dart-vm`), `browser`, `js`, `wasm`, `linux`,
`mac-os`, `windows` and `posix`. A selector that names anything else (a browser
by name, a compiler, `android`) fails the run, naming the file. So does one
whose platforms no list or single `select()` can express. In those cases, write
the attribute by hand and mark it `# keep`, as for any attribute Gazelle
manages. Gazelle logs a `target_compatible_with` it removes.

The `@platforms` labels need `bazel_dep(name = "platforms", ...)` in a workspace
whose tests name an OS.

### Analysis options

Every directory with an `analysis_options.yaml` gets a `dart_analysis_options`
named `analysis_options`. If another rule there already has that name, it is
named `analysis_options_yaml`. Its `deps` are the packages that the file's
`include: package:<pkg>/...` lines name.

In the root package, Gazelle keeps one `dart_analysis_config`, named
`analysis_config`, that lists all of them. That is the target the
`analysis_config` flag points at (see
[Static analysis and formatting](#static-analysis-and-formatting)).

A run on part of the tree (`gazelle path/to/dir`, or `-r=false`) updates only
the directories it visits, and keeps the config's other entries. So to catch an
`analysis_options.yaml` that nobody listed, run `gazelle -mode=diff` over the
whole repository in CI.

## Tests

A `dart_test` runs one test file, its `main`:

```starlark
dart_test(
    name = "parser_test",
    main = "test/parser_test.dart",
    deps = [
        ":parser",
        "@pub_deps//:test",
    ],
)
```

When `deps` lists `package:test`, as here, the test runs under `package:test`'s
own runner, built from that same `package:test` target. Bazel's test features
then work on the file's cases:

- `bazel test --test_filter=<regex>` runs the cases whose names match. A target
  with no matching case passes, so the filter can be used across `//...`.
- `shard_count` splits the file's cases across shards. A shard that draws no
  case passes.
- Each case appears in Bazel's test report (`test.xml`).
- The target's `size` or `timeout` is the time limit. `package:test`'s default
  of 30 seconds per case doesn't apply. A `timeout:` that a test states on its
  own case still does.

`package:test` must be listed in the test's own `deps`, because the runner
comes with that target. Reaching it only through a helper library isn't
enough, and fails the build with a message saying to add it.

A test that doesn't depend on `package:test` at all runs its `main` directly.
It has no cases to select, so `include_tags` or `exclude_tags` on it fails the
build. A `--test_filter`, a run's tag selection, an ordering seed or a
`shard_count` fails the test.

### Selecting cases by tag

There are two kinds of tag. Bazel's `tags` choose whole targets, with
`--test_tag_filters`. Gazelle copies a file's `@Tags` into them (see
[Test tags](#test-tags)). `package:test`'s tags choose cases inside a target.
Those come from `@Tags` on the library and `tags:` on `group` and `test`.

A target chooses its cases with `include_tags` and `exclude_tags`. Each entry is
one boolean selector, as `dart test --tags` and `--exclude-tags` take them
(`unit`, `a && !b`). A case runs when it matches every `include_tags` entry and
no `exclude_tags` entry. A target that leaves itself no case fails, since it
would never run anything.

```starlark
dart_test(
    name = "parser_test",
    exclude_tags = ["slow"],
    main = "test/parser_test.dart",
    deps = [
        ":parser",
        "@pub_deps//:test",
    ],
)
```

One run can narrow the selection further, without rebuilding:

```shell
bazel test //... --test_env=DART_TEST_TAGS=integration
bazel test //... --test_env=DART_TEST_EXCLUDE_TAGS=slow
```

These values are written as `dart test --tags` takes them, so `a,b` means
`a && b`. They combine with the target's own selection as `package:test`
combines its configuration with its command line, and with `--test_filter`. A
run's selection that leaves a target no case passes, and says on stderr which
tags that target's cases use. So the first command above runs the cases tagged
`integration`, wherever they are.

### Test order

`--test_env=DART_TEST_ORDERING_SEED=<seed>` shuffles the order of a target's
cases, as `dart test --test-randomize-ordering-seed` does. The seed is an
unsigned 32-bit integer, or `random` for a new one each run. The test's log
prints the seed it used
(`Shuffling test order with --test-randomize-ordering-seed=<seed>`), so passing
it again repeats the order. Bazel caches a passing result, so add
`--nocache_test_results` to shuffle a test that hasn't changed.

### Settings from dart_test.yaml

The runner reads no `dart_test.yaml`, neither the package's nor one at the
workspace root. Each of its settings has a place on the target or in Bazel, so
moving a package to Bazel moves them into its BUILD files:

| `dart_test.yaml`               | In Bazel                                                                                                     |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `include_tags`, `exclude_tags` | The target's attributes of the same names. `DART_TEST_TAGS` and `DART_TEST_EXCLUDE_TAGS` for one run.      |
| `timeout`                      | The target's `size` or `timeout`. A `@Timeout` or `timeout:` in the test still applies to its own cases.   |
| `retry`                        | The target's `flaky`, or `--flaky_test_attempts`.                                                           |
| `concurrency`, sharding        | `shard_count`, and Bazel's own parallelism across targets.                                                  |
| Anything else                  | No counterpart. Put cases that need other settings in a target of their own.                               |

With no file to declare tags in, the runner warns about every tag a test uses,
saying it is "not specified in dart_test.yaml". The warning is harmless under
Bazel. Creating the file doesn't silence it, and changes nothing else either.

The runner can start from a snapshot of itself cached on the machine. That
roughly halves a test's start-up (see
[Faster tests and builds](#faster-tests-and-builds-optional)).

### Where a test runs

Like any Bazel test, a `dart_test` is built for the target platform, and runs on
a host that matches it. Its native `code_assets` and its Dart VM are built for
that platform too. To run tests on another host, such as a remote Linux
executor, build them for that host's platform. Use `--platforms`, or a platform
transition on each test such as `platform_transition_test` from
`aspect_bazel_lib`.

A test runs in its package's root, as `dart test` runs it.
`Directory.current` is that root, inside the test's runfiles, so a test reads
its `data` by its path from there (`File('test/fixtures/input.json')`).

The test's package is the one whose root is the deepest directory holding the
test file. rules_dart looks among the test's own package and the packages of its
`deps` in the same repository, wherever the test's BUILD file is. A test in
`pkgs/app/test/BUILD.bazel` that depends on `//pkgs/app` runs in `pkgs/app`. A
test that no package of its repository holds runs at the repository's root,
where Bazel starts every test.

The directory holds only the test's runfiles, not the whole package. Those are
the `data` of the test and of the libraries it depends on. (A `dart_library`'s
`data` goes with every binary and test that reaches it, as with `py_library`.)
`Runfiles.rlocation()` still finds a file by its runfiles path from anywhere.

Bazel builds no runfiles tree on Windows by default. There the launcher lays out
the test's runfiles from the runfiles manifest, as a tree would hold them, and
runs the test in that copy. It leaves out the launcher's own program and the
kernels.

A test, and a `kernel` or `aot-snapshot` binary that its launcher runs, gets an
empty package config. So `Isolate.resolvePackageUri` returns null, as it does
in an `exe` installed on its own. Otherwise the VM would look upward from the
program and, without a sandbox, find the workspace's own `.dart_tool`.

A test carries only the part of the Dart SDK that runs its compiled code: the
`dart` launcher and the VM. A test that runs SDK commands itself, such as
`dart compile` or `dart analyze`, needs the whole SDK. Add `@rules_dart//dart`
to its `data`, and run that target's launcher as you would `dart`, finding it
with `$(rlocationpath @rules_dart//dart)`:

```starlark
dart_test(
    name = "cli_test",
    args = ["$(rlocationpath @rules_dart//dart)"],
    data = ["@rules_dart//dart"],
    main = "test/cli_test.dart",
)
```

### How tests are compiled

Each library is compiled once, into kernel modules that every test reaching it
links. Its dependents compile against outlines of those modules, which leave
out function bodies. So an edit inside a function body recompiles only that
library, plus the link step of each test that reaches it.

Some code keeps its source positions in the outline, because the VM copies it
into the classes that use it. That is every mixin and `mixin class`, and every
class of a library written before Dart 3.0. In those, an edit that moves code
also recompiles the library's dependents.

The outlines come from a stripper built from the source of the same Dart SDK as
the compiler. Each Dart toolchain registers one beside it. A Dart SDK of your
own needs one too (see [A Dart SDK of your own](#a-dart-sdk-of-your-own)). Two
flags turn this off:

- `--@rules_dart//dart:outline_kernel=false` compiles dependents against full
  kernels instead of outlines.
- `--@rules_dart//dart:modular_kernel=false` compiles each test's whole program
  from source.

A test's program is a kernel list: a small text file naming the kernels it
reaches, its entrypoint's first. The Dart VM loads the list as one program. So
each kernel is stored once, however many tests reach it, rather than copied into
every test. The launcher writes the list again at each run, naming each kernel
where it finds it in runfiles. That way the test runs the same under
`bazel test`, `bazel run`, a runfiles manifest (Windows) and remote execution.
To store one joined kernel per test instead, pass
`--@rules_dart//dart:kernel_list=false`.

A test's `defines` are configuration. The modules of its dependencies are
compiled in the same environment as its entrypoint: the test's `defines`, then
the `extra_dart_defines` flag. Test rules of other rule sets link the same
modules (see [Linking programs from modules](#linking-programs-from-modules)).

### Coverage

`bazel coverage` runs `dart_test` targets and records the lines they run. There
is nothing to install. The hermetic Dart VM counts what runs, and the collector
is built from rules_dart's pinned `package:coverage`.

```sh
bazel coverage --combined_report=lcov //...
```

Bazel prints where the merged LCOV report is
(`$(bazel info output_path)/_coverage/_coverage_report.dat`). Each test's own
report is `bazel-testlogs/<package>/<name>/coverage.dat`. Any LCOV tool reads
them.

The report covers the `srcs` of every `dart_library` a test reaches through
`deps`, for the libraries `--instrumentation_filter` selects. By default those
are the libraries in the packages named on the command line. Each file is
listed under its path in the workspace. It counts lines only, with no function
or branch counts.

Two kinds of file are left out unless you ask for them, as for every Bazel
language:

- A generated source, such as a `dart_codegen` or `genrule` output. Pass
  `--experimental_collect_code_coverage_for_generated_files` to include it,
  under its `bazel-out/` path.
- A test's own `main` and `srcs`. Pass `--instrument_test_targets` to include
  them.

You can leave code out with comments, as `dart test --coverage-path` does:
`// coverage:ignore-line` for a line, `// coverage:ignore-start` to the next
`// coverage:ignore-end` for a range, and `// coverage:ignore-file` for a file.
An unbalanced start or end fails the test.

A `package:test` test has its runner collect each suite. A test with a plain
`main()` runs with the VM service on, and each isolate pauses as it exits until
its coverage is read. That test must return from `main`, setting `exitCode` to
fail. A call to `exit()` ends the VM before it can pause, and under
`bazel coverage` the test then fails, saying why.

A coverage build compiles the same kernels as a test build, since the VM counts
lines in any kernel. Only the test's launcher configuration and runfiles
differ. The runfiles also carry the reported sources, which the ignore comments
are read from.

Bazel's own report merger needs a runfiles tree. So `bazel coverage` fails with
`--noenable_runfiles`, which is the default on Windows.

A test rule of another rule set collects coverage the same way (see
[Coverage in your own test rule](#coverage-in-your-own-test-rule)).

## Static analysis and formatting

`bazel test` can check two more things about your code: that the analyzer
reports nothing (`dart analyze`), and that `dart format` would change nothing.
Both checks run as an aspect, `dart_analyze`. You enable it in `.bazelrc`:

```
# .bazelrc
test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
test --output_groups=+dart_analyze
test --output_groups=+dart_format
common --@rules_dart//dart:analysis_config=//:analysis_config
```

Each check is its own output group, and a check whose group isn't requested
doesn't run. Keep the `dart_analyze` line for analysis, the `dart_format` line
for the format check, or both. The last line names a `dart_analysis_config`
listing every `analysis_options.yaml` in the repository:

```starlark
# BUILD.bazel
load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")

dart_analysis_options(
    name = "analysis_options",
    src = "analysis_options.yaml",
    deps = ["@pub_deps//:very_good_analysis"],  # packages its `include:` names
)

dart_analysis_config(
    name = "analysis_config",
    options = [
        ":analysis_options",
        "//tools:analysis_options",  # tools/analysis_options.yaml
    ],
)
```

Gazelle writes both (see [Analysis options](#analysis-options)). The flag goes
under `common`, not `test`, so that the format and fix tools below see the same
options. With no config named, every file gets the SDK's defaults.

`bazel test //...` then checks every Dart target it matches. Any diagnostic,
down to an info, fails the build.

The aspect checks only the targets the command names, and only each target's
own hand-written files:

- A target's dependencies are resolved but not checked again. Each is checked
  as a target of its own.
- Generated files are never checked.
- Targets in other repositories, such as pub packages and other Bazel modules,
  are left to the module that owns them.
- The entrypoint of a `dart_binary`, `dart_test`, `dart_js_binary` or
  `dart_wasm_binary` is checked. That is how a `main.dart` gets linted. It sits
  outside any package's `lib/`, so no `dart_library` accepts it, and it would
  otherwise be the one file nothing checks.

To skip a target's analysis, tag it `no-dart-analyze`. To skip its format
check, tag it `no-dart-format`. Each tag leaves the other check in place.

Each file is judged by the nearest listed `analysis_options.yaml` above it, as
in the IDE. The analyzer finds options files by that name, so every listed file
must have it. An options file may `include:` another listed one by relative path
(`include: ../analysis_options.yaml`). Any other yaml it includes must come from
a package, by `package:` URI, with that package in the `dart_analysis_options`'s
`deps`.

The checks run against a staged copy of your sources, not the sources
themselves. Only the listed options files and those packages are staged. So an
options file the config doesn't list is never read, whatever directory it is
in, and a relative `include:` of an unlisted file fails both checks. The
verdict can't depend on files no target declares, or on sandboxing settings.

Options files from other repositories are refused. To share a ruleset across
modules, `include:` it from an options file of your own, and put its package in
that `dart_analysis_options`'s `deps`.

The format check runs `dart format` over the same files, and fails the build
if formatting would change any of them. It takes its settings (`page_width`,
`trailing_commas`) from the `formatter:` section of the same nearest listed
`analysis_options.yaml`, including what that file `include:`s. A file under no
listed options file gets the formatter's defaults. If an options file can't be
read, because an `include:` doesn't resolve, the check fails. `dart format`
itself would fall back to defaults without saying so.

The language version selects the formatting _style_. Below `3.7`, `dart format`
writes the old short style, and from `3.7` on the tall one. The check formats
each target at its own package's `language_version`, which is set on its
`dart_package_metadata` (Gazelle copies it from `pubspec.yaml`). An
executable's entrypoint takes the version of the package it names with
`package`. Failing that, it takes the version of the package among its `deps`
whose root directory contains it (see
[Executables in a package](#executables-in-a-package)). With no version stated,
the check uses the newest the SDK knows. So a package on an older version must
state it, or the check will hold it to a different style than its own
`dart format` produces.

### Formatting and fixing

Two tools write into your sources what the checks found.
`@rules_dart//dart/format` writes what the format check computed: every file it
would reject, formatted with that file's options and at its target's language
version. The rewrite is the check's own output, so after a run the check
passes. `@rules_dart//dart/fix` does the same for `dart fix --apply`. It applies
the analyzer's automated fixes, the quick-fixes an IDE offers, for the lints your
options enable. They are computed over the same staged project the analysis
uses for each target.

```sh
bazel run @rules_dart//dart/format -- //...                 # every target of the workspace
bazel run @rules_dart//dart/format -- -- //app/... -//app/gen/...
bazel run @rules_dart//dart/format -- --config=deep //:slow_test
bazel run @rules_dart//dart/fix -- --dry-run //app:lib      # print the fixes as a diff
bazel run @rules_dart//dart/fix -- $(bazel query 'kind(dart_library, //app/...)')
```

After an optional `--dry-run`, the arguments are those of `bazel build`: its
flags and its target patterns, relative to the directory you run from. Put `--`
before patterns that start with `-`, as `bazel build -- //app/... -//app/gen/...`
needs. Each tool runs `bazel build` with those arguments and the `dart_analyze`
aspect, then writes the result. So it formats or fixes exactly the targets that
build would build, and a `bazel query` works as the arguments. Some details
follow from that:

- Flags given to `bazel run` itself build the tool, not your targets. Pass them
  after the `--`.
- A target your `.bazelrc` leaves out with `--build_tag_filters` is left out
  here too, even when named. Pass the config that includes it.
- The tool sets `--aspects`, `--output_groups`, `--run_validations` and
  `--build_event_json_file` itself, and refuses them.
- The build reads your `.bazelrc` like any other. That's why the
  `analysis_config` line goes under `common`. Under `test` alone, the tools
  would format and fix with no options.

Only each target's own hand-written files are written, as only they are
checked. A target tagged `no-dart-format` is not formatted. One tagged
`no-dart-analyze` can still be fixed. Generated files are never written: only
files Bazel records as sources are eligible, so codegen output is never edited.
A fix can make further fixes possible, so run `fix` until it fixes nothing.

`@rules_dart//dart/unused_deps` takes the same arguments and removes deps that
no file imports. See [Deps match imports](#deps-match-imports).

Nothing is written unless everything can be. Each change records the bytes it
was computed from. If a file changed since the build, or two targets would
rewrite one file differently, the whole run is refused.

### Lints

Lints are the rules an `analysis_options.yaml` enables, as in any Dart project.
The analyzer reads that file, and the package's `pubspec.yaml` plays no part. A
ruleset published as a package, such as `package:lints` or
`package:very_good_analysis`, is included by `package:` URI. Its package goes in
the `deps` of the `dart_analysis_options` that holds the file:

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
[Analysis options](#analysis-options)). The ruleset is staged only so that the
include resolves. It isn't a dependency of the code it lints, and it isn't
analyzed itself.

Some lints read the pubspec. For them, the analysis generates one from the
target's `deps` and its package's `language_version`. So
`depend_on_referenced_packages` is satisfied by `deps`, and `sdk_version_since`
judges the code against the version the package compiles at.

`// ignore:` comments and `analyzer: errors:` settings work as in an IDE. To skip
a whole target, tag it `no-dart-analyze`.

### Analysis against summaries

Each target is analyzed against analyzer summaries of its dependencies, not
their source. A summary records a library's declarations, without its function
bodies, comments or source positions. Every library gets one, written by an
action of its own.

An edit inside a function body, or to a comment, leaves the library's summary
unchanged. Bazel then re-analyzes only that library's own target, and no target
above it. An edit that changes a declaration, a private one included, changes
the summary, and the targets that depend on it are analyzed again.

The Dart SDK doesn't support this. It removed the analyzer's own way of
analyzing against summaries, its "build mode"
([dart-lang/sdk@00a45e4](https://github.com/dart-lang/sdk/commit/00a45e425a7d944ad0da5f9417e21d760bf9235e),
"Remove build mode from analyzer_cli"). It then removed the `dartanalyzer` tool
that offered it ([dart-lang/sdk#46100](https://github.com/dart-lang/sdk/issues/46100)).
No SDK command reads summaries, and `package:analyzer` reads and writes them
only in its private `src/` API.

So rules_dart builds its own analyzer from the SDK's `pkg/analyzer` and
`pkg/linter`, unmodified, taken from the source archive of the SDK's release
tag. It reports what that release's `dart analyze --fatal-infos` reports.

Analyzing against summaries runs into known analyzer bugs. Wherever the summary
analyzer can tell that the answer is wrong, it fails the analysis, giving the
reason and the flag that turns summaries off:

- **Crashes.** The analyzer crashes on some code that uses a dependency's
  declarations, such as a public nullable field that is not promoted, or a
  `const` constructor of a dependency whose evaluation fails. The library would
  get no diagnostics at all, so the analysis fails with the crash. The known
  crashes happen only on code with a compile error.
- **Swallowed exceptions.** The analyzer catches and ignores an exception in a
  lint rule, losing the rule's diagnostics. The analysis fails with it.
- **`base` and `final` class modifiers.** The analyzer doesn't report a class
  that subtypes a dependency's `base` or `final` class without being `base`,
  `final` or `sealed` itself (`subtype_of_base_is_not_base_final_or_sealed` and
  its relatives). The summary analyzer finds those classes and fails with the
  error the analyzer would have reported.
- **`prefer_relative_imports` in a package split across targets.** The lint
  doesn't fire for a `package:` import of the same package's file in another
  target. With the lint on, the summary analyzer finds those imports and fails.
- **`comment_references` from doc imports.** A name that an `@docImport` brings
  in from a dependency or from the SDK is reported as not in scope. The
  diagnostic fails the analysis anyway, and the summary analyzer says which ones
  are false.
- **Context messages.** A diagnostic's context message that points into a
  dependency ("'x' refers to a public property", "the error is in the field
  initializer of 'E'") loses its location or is left out. The diagnostic itself
  is reported as it would be.
- **Plugins and data-driven fixes.** Analyzer plugins and validation of
  `lib/fix_data.yaml` run only in the analysis server, which can't read
  summaries. A target whose options enable a plugin, or whose package has a
  `lib/fix_data.yaml`, fails.

The list comes from comparing analysis from summaries with analysis from source
over this repository, its examples, a corpus of pub packages and the analyzer's
and linter's own tests. A loss outside the list can't be detected. Analyzing
with the flag off is the reference.

The summary analyzer must be built from the same SDK release as the Dart
toolchain, and the `dart` extension registers it for its own SDK. A Dart SDK
with no release tag (Flutter's beta and main channels, a local build) has no
unmodified analyzer source to build it from. There, analysis fails and names the
flag, unless you register an analyzer toolchain built from that SDK's checkout
(see [A Dart SDK of your own](#a-dart-sdk-of-your-own)).

With the flag on, every library declares a summary, so any build configures the
summary analyzer. It fetches the SDK source archive the analyzer is built from,
the same one the outline stripper uses, and keeps it in the repository cache.
rules_java and rules_go fetch their toolchains' tools the same way. Nothing is
built until an analysis reads a summary, and a failure to build the analyzer
fails only that analysis.

To analyze against dependencies' source instead, with the SDK's own
`dart analyze`:

```sh
bazel test //... --@rules_dart//dart:analysis_summaries=false
```

`@rules_dart//dart/fix` always runs the SDK's own `dart fix`, from source.

### Analysis workers

Analysis and fixes run in Bazel persistent workers, so a tool's start-up is paid
once per worker instead of once per target. There are two kinds.

With summaries on (the default), analysis (`DartAnalyze` actions) and summary
writing (`DartSummarize`) run in workers of the summary analyzer. Each request
gets a fresh analysis context, so one request never sees another's files. The
worker saves the Dart VM's start-up, and keeps the analyzer's code compiled.

Fixes (`DartFix`), and analysis with `analysis_summaries=false`, run in workers
that each keep one Dart analysis server for the requests of a build. The
server's start-up and its analysis of the SDK are paid once per worker. Each
request is still analyzed afresh, and the result is what `dart analyze` would
print for the same files. The server stops after its worker has had no request
for a minute. The worker itself, a small process, stays with Bazel's server.

To start a fresh process for every action instead, whether the summary analyzer
or `dart analyze` and `dart fix`:

```sh
bazel test //... --@rules_dart//dart:analysis_worker=false
```

Bazel's own worker flags apply. `--worker_max_instances=DartAnalyze=N` (and
`DartSummarize=N`, `DartFix=N`) sets how many workers of each kind run at once.
An analysis server holds a few hundred MB. `--strategy=DartAnalyze=sandboxed`,
or remote execution, runs each action in a process of its own.

### Checking targets `//...` does not reach

The `.bazelrc` setup checks the targets a test run names. So it never reaches a
target tagged `manual`, or a fixture that a wildcard must not build.
`dart_analysis_test` applies the same aspect to the targets it lists:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_analysis_test")

dart_analysis_test(
    name = "fixtures_analysis_test",
    targets = [":manual_fixture"],
)
```

Both checks run on each listed target, less whichever its `no-dart-analyze` or
`no-dart-format` tag removes. They use the same `analysis_config` flag, and run
whatever output groups the command line asks for. A violation fails the build
of the test.

This rule is not how you enable the checks. The `.bazelrc` setup does that.
`dart_analysis_test` is only for what that setup can't name. Web-only code is
one case: `//...` skips it on the host, and `dart_analysis_test`'s
`web_platforms` checks it on each web platform listed (see
[Per-compiler code](#per-compiler-code)).

## Code generation

In Bazel a code generator is a target, not a `build_runner` step. rules_dart
has two rules for running one. `dart_codegen` runs a generator on one source
file. `dart_aggregate_codegen` runs a generator over many sources at once, for
generators that need a view of the whole package, such as auto_route.

```starlark
load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen")

dart_codegen(
    name = "user_g",
    src = "lib/user.dart",
    package = ":pubspec-metadata",
    generator = "@rules_dart//dart/ext/json_serializable:shim",
    output_suffixes = [".json_serializable.g.part"],  # writes lib/user.json_serializable.g.part
    deps = ["@pub_deps//:json_annotation"],           # other packages' libraries user.dart imports
)

dart_aggregate_codegen(
    name = "routes",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    generator = "//tools:route_shim",
    outputs = ["lib/router.gr.dart"],                 # the files to write, listed by hand
    deps = ["@pub_deps//:auto_route"],
)
```

A `dart_codegen` names each output after its input: the input's stem plus one
of `output_suffixes`. A `dart_aggregate_codegen` writes exactly the `outputs`
you list.

The generator is a target too. It is a `dart_binary` whose `main` passes a
`package:build` Builder to rules_dart's shim runner (`shimMain`, from
`package:rules_dart_ext/worker_entry.dart`). The shim runner speaks the rules'
command line and runs as a persistent worker. Bazel builds the generator for
the execution platform, as it builds a genrule's `tools`. The contract is in
[`docs/ext.md`](./docs/ext.md).

Because the generator is a target, the `dart_analyze` aspect checks it like any
other executable (see [Static analysis](#static-analysis-and-formatting)). The
model files it reads need nothing special. They belong to the `dart_library`
targets in `deps`, which are analyzed already.

For a source that isn't Dart, such as drift's `.drift` files, use
`dart_sqlcodegen`. It is `dart_codegen` for a non-Dart input.

You rarely write a `dart_codegen` yourself. rules_dart bundles shims for seven
third-party builders: `json_serializable`, `freezed`, `built_value`, `mockito`,
`copy_with_extension_gen`, `stacked` and `drift`. Each has macros in
`dart/ext/<builder>/defs.bzl` (`json_serializable_codegen`, `freezed_codegen`,
`copy_with_codegen`, six `stacked_*_codegen`, and so on). A macro writes the
builder's codegen targets for its `srcs`. The target it is named for collects
the generated files, and the `dart_library` holding the sources lists it in its
own `srcs`:

```starlark
load("@rules_dart//dart/ext/json_serializable:defs.bzl", "json_serializable_codegen")

json_serializable_codegen(
    name = "user_codegen",
    srcs = ["lib/user.dart"],
    asset_deps = ["lib/role.dart"],  # files of this package that user.dart imports
    package = ":pubspec-metadata",
)

dart_library(
    name = "my_pkg",
    srcs = ["lib/role.dart", "lib/user.dart", ":user_codegen"],
    package = ":pubspec-metadata",
    deps = ["@pub_deps//:json_annotation"],
)
```

The generator sees files from two attributes. `deps` are other packages'
libraries. `asset_deps` are files of its own package, such as `lib/role.dart`
above. Those can't come through a library, because the library they would come
through is the one that holds the generated output.

If you use Gazelle, it finds the annotations in your sources and writes these
macros for you. [`docs/ext.md`](./docs/ext.md) also covers how the worker
behaves and the checks for generated files checked into a source tree.

Two more `dart/ext` packages are not builders. `sqlite3`
(`sqlite3_code_asset()`) and `webcrypto` build a package's native library with
Bazel (see [Native code assets](#native-code-assets)).

To put hand-written and generated files from any targets into one directory,
use bazel_lib's `copy_to_directory`. A `dart_library` takes that directory as
`srcs_dir`.

### A generator and its package

A generated file belongs to the package whose sources it came from. So the
codegen rule and the `dart_library` that collects its output must name the same
`dart_package_metadata`. If they don't, the build fails and names both.

The generator runs at the package's language version. That is the version its
`dart_package_metadata` states, or the SDK's own if it states none. The analyzer
and the format check use the same version.

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
    generator = "//tools:gen",
    output_suffixes = [".g.dart"],
)

dart_library(
    name = "my_lib",
    srcs = ["lib/user.dart", ":user_g"],
    package = ":pubspec-metadata",
)
```

`package` names a target, so the rules that share it can sit in different BUILD
files. The builder macros take `package` too, and pass it to every rule they
write.

### Generators in packages that import each other

A generator resolves what its source imports. Usually that comes from the
libraries in its `deps`. In a `dart_package_cycle` it can't. Say `order` has a
model with a `Customer` field, and `Customer` is in `customer`. The library
holding `customer` is the cycle. The cycle holds what the generator writes for
`order`, so the generator can't depend on it.

So in a cycle a generator reads the members instead. List every member of the
cycle in its `deps`, and the libraries the cycle depends on. The generator then
sees every member's own sources, each under its package's name. This is what
build_runner does: it reads all the packages at once.

The generated files then can't be in a member, because the generators depend
on the members. They go in the cycle's `srcs`. Each file still belongs to the
package whose `lib/` holds it.

```starlark
# order/BUILD.bazel
dart_package_member(
    name = "member",
    srcs = glob(["lib/**/*.dart"]),  # the package's own files only
    visibility = ["//:__subpackages__"],
)

json_serializable_codegen(
    name = "codegen",
    srcs = ["lib/order.dart"],
    deps = [
        "//customer:member",
        "//order:member",
    ],
    visibility = ["//:__pkg__"],
)
```

```starlark
# BUILD.bazel
dart_package_cycle(
    name = "shop",
    srcs = [
        "//customer:codegen",
        "//order:codegen",
    ],
    members = [
        "//customer:member",
        "//order:member",
    ],
    deps = ["@pub_deps//:json_annotation"],
    visibility = ["//visibility:public"],
)
```

Building a generator that reads members checks their imports against its
`deps`. Leave out a member or a library that the members import, and the build
fails and names it. So a generator can't quietly miss a type. The check skips
the members' `part` directives, because the parts are what the generators are
about to write.

Gazelle writes all of this for a cycle that a `dart_cycle` directive declares.

### Executables in a package

Dart gives every file under a package's root to that package, `bin/` and
`test/` included. So a test's entrypoint compiles at the package's language
version, not the SDK's.

A `dart_binary`, `dart_test`, `dart_js_binary` or `dart_wasm_binary` says which
package it is in the way a library does: it names the package's
`dart_package_metadata` with `package`. Its BUILD file doesn't have to be the
package's. The executable's package is rooted where the metadata's is:

```starlark
# greeter/test/BUILD.bazel
dart_test(
    name = "greeter_test",
    main = "greeter_test.dart",
    package = "//greeter:pubspec-metadata",
    deps = ["//greeter", "@pub_deps//:test"],
)
```

The entrypoint then compiles, is analyzed and is format-checked at the
package's version. That holds whether or not the executable depends on one of
the package's libraries.

An executable that names no `package` adds no package of its own. Its
entrypoint takes the version of a package from its `deps` whose root contains
it. If there is none, it takes the SDK's.

The build fails, naming both sides, if an executable's package contradicts its
`deps`:

- A package in `deps` rooted at the same directory must be the same package.
- A package in `deps` with the same name must be rooted there.
- Each of the executable's own files must be under the package root, and not
  inside a package from `deps` nested within it.

## Web compilation

`dart_js_binary` compiles a Dart entrypoint to JavaScript with
`dart compile js`. `dart_wasm_binary` compiles it to WebAssembly with
`dart compile wasm`. The WebAssembly output needs a browser that supports
WasmGC.

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

### Per-compiler code

Most code that differs between native and web needs nothing from Bazel. A
conditional import on `dart.library.js_interop` picks native or web code, and
Dart handles it. But a conditional import can't tell dart2js from dart2wasm. If
those two need different declared types or different files, the build has to
choose.

The build sees the compiler as a constraint of the target platform,
`@rules_dart//dart/constraints:runtime`. It has three values:

- `js`, for dart2js and DDC.
- `wasm`, for dart2wasm.
- `vm`, the default. Every platform that doesn't mention the constraint has it,
  the host included.

A web binary builds everything it depends on for a platform with its compiler's
value. That is `@rules_dart//dart/platforms:js` or `:wasm`, unless the binary's
`platform` attribute names one of yours. A library picks a variant with a
`select()` in its `deps`:

```starlark
dart_library(
    name = "vec",
    srcs = ["lib/vec.dart"],  # import 'package:i64/i64.dart'.
    deps = select({
        "@rules_dart//dart/constraints:js": ["//i64/js:i64"],
        "@rules_dart//dart/constraints:wasm": ["//i64/typed:i64"],
        "//conditions:default": ["//i64/typed:i64"],
    }),
)
```

Each variant is a separate `dart_library` in its own directory, and all of them
have the same `package_name`. So the import is the same whichever is picked.
Building `:app` or `:app_wasm` builds only that binary's variant.

A platform of your own has the compiler's constraint value, plus any of your
own constraints that a `select()` needs. Don't give it `flags`. A platform's
flags stay set beneath the binary, including in the code it shares with VM
builds, and that code is then built twice.

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

Code generators can't vary by compiler. `dart_codegen` and its siblings are
built for the platform the build had before any web binary, so their outputs
are shared by both binaries and by the VM. If a generator needs per-compiler
output, have it write every variant, with one `dart_codegen` per variant
directory, and let the library's `select()` choose.

Some code has no VM variant. It might import `dart:js_interop`
unconditionally, for example. Mark it incompatible with the `vm` runtime in
`target_compatible_with`, as below. Then `bazel build //...` skips it on the
host, and a VM program that reaches it is incompatible too. Code with no web
variant says `target_compatible_with = ["@rules_dart//dart/constraints:vm"]`.

`bazel test //...` builds for the host, so it never analyzes web-only code. A
`dart_analysis_test` with `web_platforms` does. It checks its `targets` once on
each platform listed:

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

You might worry that every target under two web binaries is built twice. It
isn't. Only the libraries on the path from a binary to a `select()` like this
are configured once per compiler, and they run no actions. Pub packages, codegen
and native code assets go back to the build's own platform, so they are built
once. A hand-written library that can't reach per-compiler code can say so with
`runtime_independent = True`, as every pub package does. It is then built once
too.

Rules of other rule sets that build Dart for a web platform use rules_dart's
transitions (see [Web platforms in your own rules](#web-platforms-in-your-own-rules)).

## Native code assets

Many Dart packages with native code build it in a `hook/build.dart`. rules_dart
never runs a build hook. Instead, Bazel builds the native library, and you bind
it to the asset id the Dart bindings use. The chain is `cc_library` →
`cc_shared_library` → `dart_code_asset` → `code_assets`:

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
    file = ":counter_shared",
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    code_assets = [":counter_asset"],
)
```

The `asset_id` is the id the bindings resolve against. That is the `package:`
URI of the library that declares the `@Native` functions, or the id its
`@DefaultAsset` names. Every entry in `code_assets` must provide
`DartCodeAssetInfo`, as `dart_code_asset` does.

A binary's native libraries are linked into `<name>.native/` beside the
executable. Install that directory with the executable, and copy with
`cp -RL`, since its files are symlinks into the output tree. A test finds its
libraries in runfiles.

**Where to name an asset.** There are two places:

- In the `code_assets` of the `dart_binary` or `dart_test` that runs the code.
- In the `code_assets` of the `dart_package_metadata` of the package that owns
  the bindings. From there the asset reaches every binary and test that
  depends on any library of the package, and every one that is in the package
  (that names it as `package`). Upstream treats the root package like any
  other, and so does rules_dart. Each id there must be the package's own,
  `package:<package_name>/...`.

A package has one `dart_package_metadata`, so its assets are one set for all its
libraries. An asset that differs between programs isn't a fact of the package.
A test's stub library is one example, and a build for another platform is
another. Put those in the executable's own `code_assets`. Don't declare a second
`dart_package_metadata` to vary them.

**Replacing an asset.** An entry in a target's own `code_assets` replaces the
asset with the same id that its `deps` bring. That is how a test loads a
differently built library under the id a package declares. If `deps` bring two
different assets for one id, the build fails and names both.

**A prebuilt library.** `file` can also be one prebuilt library file, such as a
checked-in or `http_file` `.so`, `.dylib` or `.dll`, as `cc_import` takes one.
Its extension must be the target platform's, so a multi-platform build needs a
`select()` on the platform.

**Link modes.** `link_mode` is `dynamic_loading_bundle` by default: a library
Bazel builds (or you supply) that ships with the program. It is the only mode
that takes a `file`. `dynamic_loading_system` loads a library already on the
target system, which you name with `uri`. `dynamic_loading_executable` and
`dynamic_loading_process` look the symbols up in the executable or the running
process. `static` is refused, because neither the Dart VM nor the Flutter
engine implements it.

**Packages with a build hook.** Suppose a package has a `hook/build.dart` and
nothing replaces it. Then every `dart_binary` and `dart_test` that reaches the
package fails, naming it. Without that check you would get a program whose
`@Native` bindings fail at run time.

For a pub package, rules_dart finds the hook itself. You can supply a
replacement with `pub.from_lock(resolve = ...)`. If nothing uses the package's
native code, list it in `pub.from_lock(ignore_hooks = [...])`, or set
`pub.package(ignore_hook = True)`.

For your own package, state the hook with `build_hook` on its
`dart_package_metadata`. A rule can't look for files, so it won't find the hook
on its own. Gazelle states it for you (see [Hooks](#hooks)). Replace the hook
with the `code_assets` of the same `dart_package_metadata`. A binary's or
test's own `code_assets` don't replace a package's hook.

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

**Build tools.** A tool that never loads native code, such as a code generator,
sets `code_assets_from_packages = False` on its `dart_binary`. It then builds
none of the native libraries its packages declare, its own package's or any in
its dependency closure. It also never fails for an unreplaced hook. rules_dart's
own builder shims set it: `drift_dev` depends on `package:sqlite3`, but
generating code never calls into libsqlite3.

**Linked programs.** In a [linked](#recorded-uses-and-link-hooks) program, the
code assets of a package with a `link_hook` are that hook's input. Only the ones
the hook emits ship.

Some native code is linked into each program, keeping only the symbols that
program uses. Upstream's link hooks do this by passing
`LinkerOptions.treeshake(symbolsToKeep:)`. In rules_dart it is a
`dart_linked_code_asset` in the package's `linked_code_assets`. It names a
`cc_library` and a tool that maps the program's recorded uses to the symbols to
keep:

```starlark
dart_linked_code_asset(
    name = "ops",
    asset_id = "package:ops/ops.dart",  # the id the `@Native` bindings declare
    library = ":ops_cc",                 # a cc_library
    symbols = "//tools:ops_symbols",     # a dart_binary reading the uses
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ops",
    linked_code_assets = [":ops"],
)
```

A linked program runs the tool as `<tool> <recorded_uses.json> <output>`, and
the tool writes one symbol per line. The program then links the library with
the registered C++ toolchain into a shared library that exports just those
symbols, and ships it under the asset's id. A program that isn't linked links
the whole library. The id must be the package's own, and not also one of its
`code_assets`. The tool can't be a library of the package that names it,
because the package would then depend on itself.

**Replacements rules_dart ships.** Two packages have one, under `dart/ext`:

- `package:sqlite3` 2.0.0 and later: `sqlite3_code_asset()` from
  `@rules_dart//dart/ext/sqlite3:defs.bzl`.
- `package:webcrypto` 0.6.2: `@rules_dart//dart/ext/webcrypto:code_asset`.

You don't have to name them. When a pub package resolves to one of these
versions, from a lock or a `pub.package()`, rules_dart attaches its replacement.
A program using `package:sqlite3` needs nothing more than the dependency. Naming
one yourself, as the [`sqlite3_binary`](e2e/examples/native_assets/sqlite3_binary/)
exemplar does, builds the same library for that target:

```starlark
load("@rules_dart//dart/ext/sqlite3:defs.bzl", "sqlite3_code_asset")

dart_binary(
    name = "app",
    main = "bin/main.dart",
    code_assets = [sqlite3_code_asset()],
    deps = ["@pub_deps//:sqlite3"],
)
```

## Data assets

A package's `hook/build.dart` can also emit data assets. These are files a
program loads at run time by an id, `package:<package>/<name>`. A Flutter app
loads them through `rootBundle`.

rules_dart doesn't run the hook for these either. `dart_data_asset` binds a file
to the id the hook would give it. The file can be checked in or made by any
rule. The package's `dart_package_metadata` lists it in `data_assets`:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_data_asset", "dart_library", "dart_package_metadata")

dart_data_asset(
    name = "chime",
    src = "assets/chime.wav",
    asset_id = "package:sounds/chime.wav",
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "sounds",
    build_hook = "hook/build.dart",
    data_assets = [":chime"],
)

dart_library(
    name = "sounds",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
)
```

Each id must be in the declaring package (`package:sounds/...` above), and each
name may appear only once. Upstream requires the same of a build hook's assets.
Anything else fails the `dart_package_metadata`.

Data assets replace the build hook, as code assets do. A package whose hook
emits only data assets builds once they are declared.

They reach every program that depends on any library of the package, and every
program that is in the package (that names it as `package`). Which of them ship
depends on whether the program is linked:

- A program nothing links, such as a debug build, ships them all.
- A linked program ships what
  [`dart_program_assets`](#recorded-uses-and-link-hooks) gives it. When
  linking, upstream's build hook sends its data assets to the package's own
  link hook. So the declared assets of a package with a `link_hook` are that
  hook's input, and the hook decides which ship. Assets of packages without a
  link hook ship as they are.

`dart_binary` and `dart_test` bundle no data assets, since the Dart VM doesn't
load them. Where the files land in an application is up to the bundler
(rules_flutter's, for a Flutter app). A rule set's bundler reads what a program
ships through rules_dart's API (see
[Program assets in your own rules](#program-assets-in-your-own-rules)).

## Recorded uses and link hooks

A package can ship a `hook/link.dart` that decides what to include from how the
program uses the package. The compiler records those uses as it tree-shakes. It
records each constant instance of a `@RecordUse` class that survives
tree-shaking, and each constant call to a `@RecordUse` static method.

Two targets do the work. `dart_binary(record_use = True)` writes the uses beside
the executable. A `dart_program_assets` whose `recorded_uses` names that binary
then links the program. It runs the link hook of each of the program's packages
over the uses, and provides what the program ships as `DartProgramAssetsInfo`:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_library", "dart_package_metadata", "dart_program_assets")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "sounds",
    build_hook = "hook/build.dart",
    data_assets = [":bell", ":chime"],
    link_hook = "hook/link.dart",
)

dart_library(
    name = "sounds",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    deps = ["@pub_deps//:data_assets", "@pub_deps//:hooks", "@pub_deps//:meta", "@pub_deps//:record_use"],
)

dart_binary(
    name = "app",
    main = "bin/main.dart",
    record_use = True,
    deps = [":sounds"],
)

dart_program_assets(
    name = "app_assets",
    recorded_uses = ":app",
    deps = [":sounds"],
)
```

Without `recorded_uses`, the program isn't linked, as in a debug build. No hook
runs, and every package's declared assets ship.

Uses are recorded only in the `exe` and `aot-snapshot` modes. The `kernel` mode
doesn't tree-shake, so its hooks see no uses.

**What a hook receives.** A hook gets its package's declared
[data assets](#data-assets) as `input.assets.data`, as a build hook routes them
to it. It gets its package's declared [code assets](#native-code-assets) as
`input.assets.code`, with the target in `input.config.code`.

**What ships.** Every data asset a hook emits ships, beside the declared assets
of packages with no link hook. A hook emits data assets of its own package only.
Code assets work by selection. Each code asset the hook emits ships, and the
ones it doesn't emit don't, as upstream ships only what a link hook emits of
the assets routed to it.

A hook must keep a code asset as its package declares it, under the same id and
link mode. The program's kernel maps every id before any hook runs, so an asset
under another id wouldn't load. A hook may not emit native code it builds
itself, and the build fails naming the file. Native code linked for each
program is a package's `linked_code_assets` instead (see
[Native code assets](#native-code-assets)). The program links it with the C++
toolchain over the same uses.

What a hook emits may depend on the program. The `sounds` hook above ships only
the sounds the program plays. So a package's emitted data assets land in one
output directory per package, each file at its name.

**Reading what ships.** The target's output, `<name>.program_assets`, lists
what ships, and its runfiles hold every file. A test or program with the target
in its `data` reads it with `ProgramAssets.read` from
`@rules_dart//dart/program_assets` (see
[Program assets in your own rules](#program-assets-in-your-own-rules)).

**Naming a hook's asset in advance.** Bazel names every file before anything
runs. A rule that needs one of a hook's assets by name at analysis time can't
wait for the hook. Instead, list the id in the `link_hook_assets` of the
package's `dart_package_metadata`. That is a promise that the hook emits it in
every program. Each promised id gets a file of its own, which
`program_asset_file()` returns. The hook may emit other assets as well.

**When the build fails.** It fails, naming what to change, when a hook:

- fails, with the hook's own message, or writes no output.
- doesn't emit an id it promises.
- emits an asset of another package, or one id twice.
- emits a name that isn't a relative path, two names that differ only in case,
  or a name that is a directory of another.
- emits a code asset that isn't one of its package's as declared.
- emits an asset that is neither data nor code.
- routes assets to another package's link hook. rules_dart doesn't support
  this: each hook runs on its own.

**The program's own package.** It is linked like the packages in `deps`. Name
it in `package` on the `dart_program_assets`, as the `dart_binary` in
`recorded_uses` does. The two must agree. Its hook then runs and its assets
ship.

**A hook's imports.** These are `deps` of the package's library, as pub
requires. The hook of the program's own package may also import from the
program's `deps`, and the program's own files under the package's `lib/`.

rules_dart sets `link_hook` for pub packages that ship one. Gazelle sets it for
your own (see [Hooks](#hooks)).

## Without a pubspec.yaml

A rules_dart workspace needs no `pubspec.yaml` and no `pubspec.lock`. Every fact
a pubspec states has a home in Bazel:

| The pubspec states | Bazel states it as |
| --- | --- |
| `name` | `package_name` on the package's `dart_package_metadata`, or `# gazelle:dart_package_name` for Gazelle. With no `dart_package_metadata`, the name of the package root directory. |
| `environment.sdk`, its lower bound | `language_version` on the `dart_package_metadata`, or `# gazelle:dart_language_version`. If unstated, the SDK's own. |
| `dependencies`, `dev_dependencies` | The `deps` of the target that imports the package. Gazelle writes them from the imports. |
| The versions in `pubspec.lock` | `pub.package()` declarations, each with `version` and `sha256` (see [Using pub.dev packages](#using-pubdev-packages)). Each version is a minimum, and the build uses the highest any module asks for (see [Versions](#versions)). |
| `dependency_overrides` | Nothing can force a lower version. To build a target of yours in a package's place, use a lock's `pub.from_lock(resolve = ...)`. |
| `hook/build.dart`, `hook/link.dart` | `build_hook` and `link_hook` on the `dart_package_metadata`. What the link hook promises to emit is `link_hook_assets`. |
| Native libraries a hook would build | `code_assets` on the `dart_package_metadata` (see [Native code assets](#native-code-assets)). |
| Data assets a hook would emit | `data_assets` on the `dart_package_metadata` (see [Data assets](#data-assets)). |
| The license file | `license_file` on the `dart_package_metadata`. |
| `executables:` | A `dart_binary`. |

[`e2e/examples/fixtures/no_pubspec`](e2e/examples/fixtures/no_pubspec/) is the worked example. A test
in it fails if a `pubspec.yaml` or `pubspec.lock` appears in it or in any
directory above it. The workspace's `MODULE.bazel` declares `json_annotation`
and `meta`. `app/BUILD.bazel` and
`greet/BUILD.bazel` each state their package's name and language version once,
in a `dart_package_metadata`. In `app`, the `json_serializable_codegen` and the
`dart_library` share it.

Gazelle works without a pubspec too. It takes a package's root to be the
directory above its `lib/`, `bin/` and `test/`. The package's name is the root
directory's, unless a `dart_package_metadata` or
`# gazelle:dart_package_name` states one. An import of `package:foo/...`
becomes a dep on `@foo`, the repository `pub.package(name = "foo")` creates. With
`# gazelle:dart_pub_deps_repo pub_deps`, it becomes a dep on
`@pub_deps//:foo` instead.

Analysis, tests and code generation need no pubspec either. Where a tool reads
one, rules_dart generates it from the target's `deps` and package metadata.

What you give up is pub's resolver. With no `pubspec.yaml`, `pub get`,
`pub add`, `pub upgrade` and `pub outdated` have nothing to work on. There is
no lock, so no tool chooses versions for you:

- You write a `pub.package()` for every third-party package, and pick its
  version. Its `sha256` is the `archive_sha256` in
  `https://pub.dev/api/packages/<name>/versions/<version>` (see
  [The sha256 of a `pub.package()`](#the-sha256-of-a-pubpackage)).
- A package is built with the dependencies its own pubspec states, and each of
  those must be declared too. So you write the whole transitive closure. A
  missing one fails the fetch, naming both packages.
- To upgrade, you edit the version and digest by hand.
- A package you publish to pub.dev still needs its `pubspec.yaml`.

A workspace can mix both. A package with a pubspec and one without can sit side
by side. A `pub.package()` and a `pub.from_lock()` lock can both ask for the
same package, and the higher version is built. If a pubspec and a directive or
`dart_package_metadata` state the same fact differently, Gazelle fails and names
both (see
[pubspec.yaml and the package's metadata](#pubspecyaml-and-the-packages-metadata)).

## Faster tests and builds (optional)

rules_dart's defaults work everywhere Bazel runs. The settings below make
builds and tests faster where your setup allows them. Each asks something of
you. Put them in your `.bazelrc`.

**Start the test runner from a cached snapshot.** This roughly halves a
`package:test` test's start-up: about 330 → 160 ms on macOS, and
1050 → 400 ms on Linux.

```
test --@rules_dart//dart:runner_snapshot
```

The runner then starts from a snapshot of itself, cached on the machine. The
snapshot is trained once per `package:test` runner and Dart SDK, by the first
test that finds none. After that test runs, the launcher loads its file again
with no case selected, and the VM records the runner's compiled code.

The cache is outside Bazel, because a snapshot's bytes differ from one training
to the next. It can't change a test's result, only how fast the runner starts.
It keeps the eight snapshots used most recently, in:

- `/tmp/rules_dart-<uid>/runner` on macOS.
- `/dev/shm/rules_dart-<uid>/runner` on Linux.
- `%LOCALAPPDATA%\rules_dart\runner` on Windows.

The first two are cleared at reboot. To put the cache elsewhere, pass
`--test_env=RULES_DART_RUNNER_SNAPSHOT_DIR=<dir> --sandbox_writable_path=<dir>`.
If anything goes wrong with the cache, the test fails and says so.

Turn it on only where tests run on your own machines. The cache needs a
directory that every test can write to and that outlives a test. A remote
executor may have none, which fails every test. Or it may give each action a
fresh one, so every test trains a snapshot and then throws it away. If your
executor keeps a writable `/dev/shm` between actions, with room for the
snapshots (about 50 MB for each `package:test` version and Dart SDK), the cache
works there too. Otherwise, turn it on under a config that only local runs use:

```
test:local --@rules_dart//dart:runner_snapshot
```

**Share actions between configurations (Linux, macOS, remote execution).** A
library built in two configurations compiles twice. That happens when it is
built for both the host and the target, or across a platform transition. With
path mapping, one result serves both:

```
common --enable_platform_specific_config
common:linux --experimental_output_paths=strip
common:macos --experimental_output_paths=strip
```

Bazel runs a path-mapped action only in a sandbox or remotely. On Windows it
fails the build, so leave it off there. If you have rules of your own that pass
a configuration's output path to an action as a string, rather than as a
`File`, fix them first (see [Architecture](docs/ARCHITECTURE.md)).

## Flags

These are all the command-line settings rules_dart reads. Set one per
invocation, or in `.bazelrc` as
`common --@rules_dart//dart:<name>=<value>`.

Build tools, such as codegen builders or any `cfg = "exec"` Dart tool, are built
the same whatever you set most of these to. Three are the exception:
`modular_kernel`, `outline_kernel` and `analysis_summaries` keep Bazel's default
scope, so they apply in the exec configuration too. `outline_kernel` and
`analysis_summaries` need that because the tools they select are themselves
resolved in the exec configuration.

| Flag                                               | Default     | What it does                                                                                                                                                                                   |
| -------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--@rules_dart//dart:analysis_config=<label>`      | none listed | The `dart_analysis_config` whose options analysis, fixes and formatting use. With none listed, every file gets the SDK's defaults.                                                             |
| `--@rules_dart//dart:analysis_summaries`           | on          | Analyzes each target against analyzer summaries of its dependencies (see [Analysis against summaries](#analysis-against-summaries)). Off, it analyzes their source.                            |
| `--@rules_dart//dart:analysis_worker`              | on          | Runs analysis and fixes in persistent workers (see [Analysis workers](#analysis-workers)). Off, each action starts a process.                                                                  |
| `--@rules_dart//dart:extra_dart_defines=KEY=VALUE` | none        | Adds an environment declaration to every Dart compile, after target `defines`. Repeat it for more.                                                                                             |
| `--@rules_dart//dart:kernel_list`                  | on          | Runs each test from a kernel list naming the kernels it reaches. Off, each test stores one joined kernel.                                                                                      |
| `--@rules_dart//dart:modular_kernel`               | on          | Compiles each library once into kernel modules that tests link. Off, each test compiles its whole program from source.                                                                         |
| `--@rules_dart//dart:outline_kernel`               | on          | Compiles dependents against outlines of their dependencies' modules, made by the Dart SDK's outline toolchain. Off, they compile against full kernels.                                         |
| `--@rules_dart//dart:runner_snapshot`              | off         | Starts the `package:test` runner from a snapshot cached on the machine (see [Faster tests and builds](#faster-tests-and-builds-optional)). Off, it starts from its kernel and touches no cache. |
| `--@rules_dart//dart:split_debug_info`             | off         | Leaves an `exe`'s or `aot-snapshot`'s debugging information out of it, and writes it to `<name>.symbols` in the `debug_info` output group. Stack traces then print as addresses.              |
| `--@rules_dart//dart:track_creation_locations`     | off         | Compiles VM kernels with `--track-creation-locations` (`--track-widget-creation`).                                                                                                             |

## For rule-set authors

This section is for rules in other rule sets, such as rules_flutter's, that
build on rules_dart's. If you only use rules_dart's own rules, you can skip it.
The API is in `@rules_dart//dart:utils.bzl`, `@rules_dart//dart:providers.bzl`
and `@rules_dart//dart:toolchain.bzl`.

### Linking programs from modules

rules_dart compiles each library once into a kernel module (see
[Tests](#tests)). A rule set's own test or executable can link those modules
into its program, as `dart_test` does. The steps, all from
`@rules_dart//dart:utils.bzl`, are:

1. Make a module aspect with `dart_module_aspect(kernel_sdk)`, once per
   platform, at the top level of a `.bzl` file. Attach it to the rule's `deps`.
2. Gather the modules with `collect_modules(deps)`.
3. Compile the entrypoint against them with `dart_entry_kernel_action`.
4. Link the entry and the modules it reaches with `dart_link_kernel_action`.
   With `kernel_list = True`, the output is a kernel list: a text file naming
   the kernels, which the VM reads as one program. `kernel_list(ctx)`, with
   `KERNEL_LIST_ATTR` merged into the rule's `attrs`, says whether the build
   wants one.

The rule's launcher reads, joins or rewrites the program's kernel list with the
`@rules_dart//dart/kernel_list` library (`package:kernel_list/kernel_list.dart`):

- `kernelsInRunfiles` finds a program's kernels through runfiles.
- `writeKernelList` writes a list naming them.
- `joinKernels` joins them for a process that takes a single kernel file. On
  Linux the joined program is in memory. Elsewhere it is a temporary file.

The rule must also honour the `modular_kernel` escape hatch. It merges
`MODULAR_KERNEL_ATTR` into its `attrs`. When `modular_kernel(ctx)` is false, no
module is compiled, so it compiles its whole program with
`dart_whole_program_kernel_action`. `dart_entry_kernel_action` fails if it is
called then.

### Environment declarations

An executable's `defines` are configuration, not just flags to its own compile.
Its dependencies' modules are compiled in the same environment as its
entrypoint. A rule set's executable gets that environment from
`executable_defines_config` in `@rules_dart//dart:utils.bzl`. Call it once per
rule kind, at the top level of a `.bzl` file. It takes a function that derives
more declarations from the rule's other attributes:

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
`extra_dart_defines` flag. A derived key that `defines` also sets is an error.

`dart_entry_kernel_action` compiles the entrypoint in this environment. It
fails if a dependency's modules were compiled in another. A compile the rule
runs itself, such as one of the whole program, takes `executable_defines(ctx)`.

### Coverage in your own test rule

A test rule that collects coverage from a Dart VM of its own, as a Flutter test
does, can reuse rules_dart's conversion to LCOV. The rule:

1. Merges `COVERAGE_ATTRS` from `@rules_dart//dart:utils.bzl` into its `attrs`.
   These are the converter and the `_lcov_merger` that Bazel's coverage runner
   needs.
2. Gives its result `coverage_common.instrumented_files_info`.
3. Calls `test_coverage(ctx, packages, sources, deps)`. `packages` are the
   `DartPackageInfo` records of every package the test runs
   (`collect_packages(deps)` and the test's own). `sources` are the test's own
   Dart files, and `deps` its dependency targets.

`test_coverage` returns `None` unless the build is for coverage. Otherwise it
writes a file naming each package's `lib/` directories and the runfiles path of
each source Bazel instruments. It returns a struct with:

- `converter`, the converter's runfiles path.
- `sources`, the runfiles path of that file.
- `runfiles`, to merge into the test's. They carry the sources, whose
  `coverage:ignore` comments the converter reads.

Inside the test, run `@rules_dart//dart:coverage_converter` over a directory of
`package:coverage` JSON, which is what `collect` returns, one file per suite:

```sh
coverage_converter --hitmaps=<dir> --sources=<sources> --output=$COVERAGE_DIR/<name>.dat
```

`--hitmaps` is searched for `*.json` at any depth. If one script appears in
several files, its counts add. `--output` must end in `.dat` and be in
`COVERAGE_DIR`.

Bazel's `COVERAGE_MANIFEST` must be set, and so must the test's runfiles
variables. A process the test starts inherits them. A script the manifest
doesn't list isn't reported.

The exit status is 0 for success and 2 for a usage error. Any other value is a
failure, with a message on stderr. These flags are stable.

### Web platforms in your own rules

A rule set that builds Dart for a web platform uses the transitions in
`@rules_dart//dart:utils.bzl`. It never sets `--platforms` alone. The
transitions record the platform the build had before, and that is what the
resets go back to. There are three ways in:

- `web_platform_transition`, to the platform in the rule's `platform`
  attribute.
- `web_platforms_transition`, a split with one branch per platform in the
  rule's `web_platforms` attribute.
- `web_platform_settings(settings, platform)`, in a transition of your own. It
  takes `WEB_PLATFORM_SETTINGS` among its `inputs` and `outputs`.

A split may see fewer keys in `ctx.split_attr` than it returned. Branches that a
dependency's reset brings back to one configuration arrive as one key.

The resets are exported too. `runtime_reset` goes back to the earlier platform.
`non_dart_transition` also turns off `track_creation_locations` and clears an
executable's environment declarations, for a rule nothing of which is compiled
Dart.

The rule set's analysis tests take
`config_settings = web_platform_config_settings(platform)`. That gives the same
settings as a fixed dict. It assumes the tests run on the host platform. Pass
`platforms` if they run under another `--platforms`.

### Program assets in your own rules

What a program ships is the result of one operation, over the program, its
packages and whether it is linked. A bundler takes its assets from that
operation, not from the packages, so that every consumer agrees.
`dart_program_assets` performs it as a target. Inside a rule,
`dart_program_assets_actions()` from `@rules_dart//dart:utils.bzl` performs it:

```starlark
load("@rules_dart//dart:utils.bzl", "PORTABLE_EXEC_GROUPS", "PROGRAM_ASSETS_TOOLCHAINS", "dart_program_assets_actions", "program_assets_action_args", "program_assets_attrs", "vm_code_config")

def _bundle_impl(ctx):
    assets = dart_program_assets_actions(
        ctx,
        package = package,               # the program's own DartPackageInfo, or None
        deps = ctx.attr.deps,
        name = ctx.label.name,
        recorded_uses = recorded_uses,   # its DartRecordedUsesInfo to link it; None not to
        code_config = vm_code_config(ctx),
    )
    a = program_assets_action_args(ctx.actions, assets.info)
    ctx.actions.run(
        executable = ctx.executable._bundler,
        arguments = [args, a.args],      # the tool gets --program-assets=<file>
        inputs = depset(inputs, transitive = [a.inputs]),
        execution_requirements = {"supports-path-mapping": "1"},
        ...
    )
    return [OutputGroupInfo(_validation = depset(assets.validation_outputs)), ...]

bundle = rule(
    implementation = _bundle_impl,
    attrs = {...} | program_assets_attrs(),
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,  # includes the C++ toolchain, for linked_code_assets
    fragments = ["cpp"],
)
```

**When to link.** Link a release build and not a debug one, as `flutter build`
does. The program's packages are `program_packages(package, deps)`, its own
among them.

**`code_config`.** A linked program passes `code_config`. It is what each hook
is told about a target that loads code assets, as upstream's hook input has it
at `config.extensions.code_assets`: `target_os`, `target_architecture`,
`link_mode_preference`, and `ios` or `android` there. For a Dart VM program use
`vm_code_config(ctx)`. For a target that loads no code assets, such as the web,
pass `None`.

**Handing assets to a tool.** `program_assets_action_args(ctx.actions, info)`
returns `args`, an `Args` of its own, and `inputs`, every File it names. The
tool gets one flag, `--program-assets=<file>`. The file is a param file Bazel
writes from the action's mapped command line. So every path in it opens
correctly under path mapping, in a sandbox, in a worker, or remotely.

A Dart tool reads the file with `ProgramAssets.read(path)` from the
`@rules_dart//dart/program_assets` library. It returns what ships, sorted by id:

- data assets, with `package`, `name` and `file`.
- code assets, with `id`, `linkMode`, `file`, `fileName` and `uri`.

Where each lands in the application is the bundler's decision. For debugging,
`@rules_dart//dart/program_assets:list` prints the same list.

**Handing a tool only what it reads.** An action waits on and reruns for only
what it is given. Two arguments narrow it:

- `data = False` leaves out the data assets.
- `code` says what the tool reads of the code assets. `"libraries"` (the
  default) gives each with its library. `"names"` gives each one's id, link
  mode, library file name and uri, without the library, as a tool writing a
  manifest needs. `None` gives no code assets.

Either code view includes each link hook's choice of which ship. The file says
what it holds. `ProgramAssets.data` or `.code` throws for what it doesn't hold,
and a file holding the code by name has no library paths.

**The kernel's code assets.** `program_kernel_code_assets(info)` is the
`DartCodeAssetInfo` of every code asset the program can load, linked or not.
That is the ones that ship, plus every one a link hook chooses among, since the
kernel's mapping is made before any hook runs. A rule that compiles the
program's kernel maps these. `dart_binary` and `dart_test` embed theirs from it.
They pass their own `code_assets` as `dart_program_assets_actions()`'s
`code_assets` argument, which replace the packages' assets with the same id.

**One asset by id.** `program_asset_file(info, id)` is the File of one asset
known at analysis time. Unlinked, that is any asset. Linked, it is:

- the assets of packages without a link hook.
- every package's `linked_code_assets`.
- the ids each hook promises in `link_hook_assets`.

For any other id it fails, naming the `link_hook_assets` to add.

**The provider.** `DartProgramAssetsInfo` holds the facts these helpers read:

- `data_assets` and `code_assets`, by id: what certainly ships.
- `link_outputs`: for each package whose hook ran, its output directory, the
  code assets it chose among, and the file of the ids it kept.

Read it through the helpers. A consumer that reads only `data_assets` and
`code_assets` misses what the hooks emit.

**Validation.** Put the result's `validation_outputs` in the rule's
`_validation` output group. Then every hook runs whenever the target builds.

#### The program-assets file

This is the file `program_assets_action_args()` hands a tool, and the one a
`dart_program_assets` target writes for its runfiles. `ProgramAssets.read` is
the reference reader. A tool in another language reads it as described below.

To check a reader, use the conformance fixture in
`dart/program_assets/test/conformance/`. Read in that directory,
`program.params` lists what `expected.txt` says, and `code_names.params` lists
what `code_names.expected.txt` says. The expected files are in the format
`@rules_dart//dart/program_assets:list` prints.

The file is text with one item per line, and each line ends in a newline. There
is no quoting. An item is a whole line, and an empty line is an empty item.

It starts with a header of three flags:

- `--format`, then `rules_dart_program_assets/1`. Refuse any other value: it is
  another format or version.
- `--paths`, then `exec` or `runfiles`. `exec` paths are relative to the
  working directory, as an action has them. `runfiles` paths are to resolve
  with a runfiles library.
- `--holds`, then what the file holds, separated by spaces: `data`, and either
  `code` (the code assets with their libraries) or `code-names` (the code
  assets by name). Refuse a record of anything the file doesn't hold.

Then come records. Each is a tag line followed by a fixed number of lines:

- `--data-asset`, its id (`package:<package>/<name>`), and its file: a data
  asset that ships.
- `--link-data`, a package, and a directory: the data assets one package's link
  hook emitted. Each file under the directory, at any depth, is a data asset of
  the package that ships. Its name is its path in the directory, with `/`
  separators. Follow symbolic links, because a sandbox stages files as links.
- `--code-asset`, its id, its link mode, its library or an empty line, and its
  uri or an empty line: a code asset that ships. The link mode is upstream's
  `link_mode.type` (`dynamic_loading_bundle`, `dynamic_loading_system`, …).
  Under `code` the library is a path. Under `code-names` it is the library's
  file name, since the library isn't there to open.
- `--link-code`, a package, and a selection file, followed by one or more
  `--candidate` records laid out like `--code-asset`: the code assets one
  package's link hook chose among. The selection file names the candidates
  that ship, one per line. The ones it doesn't name don't ship.

An id appears only once in all that ships. `--data-asset` and `--code-asset`
records, and each `--link-code`'s candidates, are sorted by id. A reader should
assume no other order.

### Analyzable targets

The `dart_analyze` aspect checks a library by its `DartInfo`. It checks an
executable by its `DartAnalyzableInfo`. An executable returns that instead of
`DartInfo`, so it can be analyzed without being a valid `deps` entry.

Build these providers with the functions in `@rules_dart//dart:utils.bzl`,
never by hand. `DartInfo` comes from `dart_info()`. `DartAnalyzableInfo` comes
from `dart_analyzable_info()` for a target whose sources belong to a package, or
`dart_analyzable_info_no_package()` for one whose sources don't.

### Reading a pubspec

A repository rule can read a `pubspec.yaml` the way `pub.from_lock()` does, with
`read_pubspec(rctx, package_name)` from `@rules_dart//dart/pub:pubspec.bzl`. It
uses Dart's own `package:yaml`, the loader pub uses, and refuses what pub
refuses, with pub's message. It returns the pubspec's `name`, `dependencies`,
`sdk_constraint` and `language_version`, and the whole document as `fields`.

### A Dart SDK of your own

Each Dart toolchain registers two tools beside the compiler: the outline
stripper (see [Tests](#tests)) and the summary analyzer (see
[Analysis against summaries](#analysis-against-summaries)). Both are built from
the source of the same SDK release.

A Dart SDK with no release tag has no such source to fetch. That includes a
fork, a local build, and Flutter's beta and main channels. It needs its own
tools, built from its source checkout. In a Flutter engine checkout that is
`third_party/dart`. Each has an off switch if you'd rather not build it.

**Outlines.** Register a `dart_outline_toolchain`, from
`@rules_dart//dart:toolchain.bzl`. Its `tool` is the `:outline_tool` of a
`dart_kernel_source(path = "<checkout>")` repository, built on that checkout's
`pkg/kernel`. Or turn outlines off with
`--@rules_dart//dart:outline_kernel=false`.

**Summaries.** Register a `dart_analyzer_toolchain`, from the same file. Its
`tool` is the `:summary_analyzer` of a
`dart_analyzer_source(path = "<checkout>")` repository, built on that
checkout's `pkg/analyzer` and `pkg/linter`. Or turn summaries off with
`--@rules_dart//dart:analysis_summaries=false`.

`dart_kernel_source` and `dart_analyzer_source` are repository rules in
`@rules_dart//dart:repositories.bzl`, for `use_repo_rule`. A repository rule of
your own that already reads the checkout can call
`fetch_dart_kernel_source(rctx, path, prefix)` or
`fetch_dart_analyzer_source(rctx, path, prefix)`, from the same file. These put
the same packages and tool in a directory of its own repository.

Each toolchain's `version` is that of the Dart toolchain whose kernels or
analysis it serves. Set its `tool` only when its flag is on, so that the tool
isn't built otherwise. For example:
`select({"@rules_dart//dart:is_outline_kernel": ..., "//conditions:default": None})`,
or `:is_analysis_summaries` for the analyzer.

## Examples

[`e2e/examples`](e2e/examples/) is one Bazel workspace with a small working
example of each feature: hello world, library deps, tests, analysis, fixes,
codegen and the bundled builders, native assets and link hooks, web
compilation, cross-compilation, Gazelle, your own rules, and pub packages from
`pub.package()`, a lock, `resolve`, `path` and git. Its
[README](e2e/examples/README.md) lists where each is. Run them all with
`bazel test //...` in that directory.

[`e2e/smoke`](e2e/smoke/) is the install instructions, used from an outside
module as the Bazel Central Registry checks them. The rest of `e2e/` is tests:
`e2e/examples/fixtures` holds the examples' edge cases, `e2e/root_settings`
the cases that need a root-level setting of their own, and `e2e/failures` the
workspaces that must fail to resolve, each with the error it must give.

> **Note**: Only the `exe` and `aot-snapshot` compile modes cross-compile with
> `--platforms`. `kernel` is a VM format and ignores target flags.
>
> Built for the host, a `kernel` or `aot-snapshot` target's executable is a
> launcher that runs the output in the SDK's VM. So it works with `bazel run`
> and as another target's `data`. Cross-compiled, the target's executable is
> the output itself, for the target's own runtime to run.
>
> The Linux targets are `linux-x64`, `linux-arm64`, `linux-riscv64` and
> `linux-arm` (armv7, selected by `@platforms//cpu:armv7`). Every supported host
> can build for all of them. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
> for details.
