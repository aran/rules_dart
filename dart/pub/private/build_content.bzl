"""The BUILD file shape every pub spoke repository carries.

`pub.package()` and `pub.from_lock()` each materialise a pub.dev package as
its own repository holding a single `dart_library`. Both emit that target
through the one generator here, so a field added to the shape reaches both
paths instead of only the one whose template was edited.
"""

_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_library")\n'

_TEST_LIBRARY = "test_library"

_TEST_RUNNER_LOAD = """\
load("@rules_dart//dart:defs.bzl", "dart_binary")
load(
    "@rules_dart//dart/private:dart_test_runner.bzl",
    "dart_test_package",
    "dart_test_runner_main",
)
"""

# `package:test`'s spoke also builds the runner `dart_test` runs tests through,
# from this same package, so the two can never be different versions. Built
# once here and shared by every test that depends on `package:test`.
_TEST_RUNNER_BLOCK = """\
dart_test_runner_main(name = "test_runner_main")

dart_binary(
    name = "test_runner",
    compile_mode = "kernel",
    main = ":test_runner_main",
    deps = [":{library}"],
)

dart_test_package(
    name = "test",
    library = ":{library}",
    runner = ":test_runner",
    visibility = ["//visibility:public"],
)
""".format(library = _TEST_LIBRARY)

def make_dart_library_build_content(name, deps, language_version, code_assets = [], has_unreplaced_hook = "", version = ""):
    """Generate the BUILD.bazel content for a single `dart_library` spoke.

    The shape — `srcs = glob(["lib/**/*.dart"], allow_empty = True)`, the
    non-Dart remainder of `lib/` as `resources`, a `package_name` matching the
    target name, public visibility, optional deps block — is the canonical
    pub-spoke layout. Resource-only and Swift-only/Kotlin-only Flutter platform
    packages produce empty source globs but must still resolve as labels, hence
    `allow_empty`.

    The two globs partition `lib/` rather than covering only the Dart half of
    it. A published package's `lib/` is addressable as `package:<name>/<path>`
    whatever the extension, so a spoke that keeps only `*.dart` is a package
    with pieces missing — `dwds` without the client JavaScript it serves,
    `lints` without the YAML every `analysis_options.yaml` includes. Whatever
    a future package ships lands in one of the two globs, so nothing is
    dropped for being unanticipated.

    Args:
        name: Target name (also the `package_name` for the dart_library).
        deps: List of fully-qualified Bazel label strings for sibling spokes
            (e.g. `"@hub__dep//:dep"`). Pass an empty list for no deps.
        language_version: Dart language version string (e.g. `"3.0"`),
            usually derived from the package's pubspec SDK constraint via
            `derive_language_version`.
        code_assets: List of `dart_code_asset` label strings replacing this
            package's `hook/build.dart` output. Attaching them here rather
            than at the consuming binary is what makes them propagate: they
            become part of the package's own metadata.
        has_unreplaced_hook: Path of a build hook this package ships that has
            no replacement, or empty. Recorded so a consuming binary can fail
            with an explanation instead of at runtime.
        version: The resolved package version this spoke was fetched at, or
            empty. A trailing keyword with a default because this helper is
            re-exported for rule sets outside //dart/pub — notably
            rules_flutter's `flutter_pub_package` — whose existing calls must
            keep working; a spoke that omits it simply states no version, and
            an unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    assets_block = ""
    if code_assets:
        asset_lines = ['        "{}",'.format(a) for a in code_assets]
        assets_block = "    code_assets = [\n{}\n    ],\n".format("\n".join(asset_lines))

    hook_block = ""
    if has_unreplaced_hook:
        hook_block = '    has_unreplaced_hook = "{}",\n'.format(has_unreplaced_hook)

    version_block = ""
    if version:
        version_block = '    version = "{}",\n'.format(version)

    library = """\
dart_library(
    name = "{target}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{assets}{deps}{hook}{version}    package_name = "{name}",
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "{language_version}",
    visibility = ["{visibility}"],
)
""".format(
        # `package:test` keeps its public name for the target that carries the
        # runner beside it; see `_TEST_RUNNER_BLOCK`.
        target = _TEST_LIBRARY if name == "test" else name,
        name = name,
        assets = assets_block,
        deps = deps_block,
        hook = hook_block,
        version = version_block,
        language_version = language_version,
        visibility = "//visibility:private" if name == "test" else "//visibility:public",
    )
    if name != "test":
        return _LOAD + "\n" + library
    return _LOAD + _TEST_RUNNER_LOAD + "\n" + library + "\n" + _TEST_RUNNER_BLOCK
