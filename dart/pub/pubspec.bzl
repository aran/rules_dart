"""Reads a pubspec.yaml in a repository rule, as pub reads it.

`read_pubspec` runs rules_dart's pubspec reader: Dart's own `package:yaml`,
the loader pub uses, compiled once per host. The file is read exactly as pub
reads it, and refused where pub refuses it, with pub's message, naming the
package. Any repository rule can call it, in any module: rules_dart's pub
repositories do, for hosted packages and for packages fetched another way.
"""

load("//dart/pub/private/pubspec_reader:reader.bzl", "run_pubspec_reader")

def read_pubspec(rctx, package_name, version = "", pubspec = "pubspec.yaml", locked_versions = None):
    """Reads a package's pubspec, saying so where pub would refuse it.

    pub's checks apply to the fields this returns: `name` must be the package's,
    each dependency must be named and specified as pub requires, and every
    version constraint, `environment.sdk` among them, must be a string.

    A refusal is about the package, so it is a value: `fail(result.error)`, or
    fetch anyway and fail only the builds using the package, as rules_dart's pub
    repositories do, since `bazel fetch --all` and `bazel vendor` fetch packages
    no build uses. So is a host with no Dart SDK, where no pubspec can be read.
    A reader that does not run or answers nonsense is no refusal: nothing is
    known of the package, so that fails the fetch.

    Args:
        rctx: The `repository_ctx`.
        package_name: The name the package is fetched as, which the pubspec's
            `name` must match, as pub requires; None to take any valid name,
            for a pubspec read for itself rather than as a package's.
        version: The package's version, for messages; empty for none.
        pubspec: The pubspec's path, relative to the repository.
        locked_versions: The version the caller will build each of some
            packages at, by name, to compare with the pubspec's constraints.

    Returns:
        `struct(error, pubspec)`. `error` is the message for a pubspec pub
        refuses, naming it and giving pub's words, or says that this host has no
        Dart SDK, and `pubspec` is then None.
        Otherwise `error` is None and `pubspec` is a `struct`:
        - `name`: the `name` field.
        - `dependencies`: the names under `dependencies:`, in order.
        - `sdk_constraint`: `environment.sdk`, or "" for none.
        - `language_version`: the `<major>.<minor>` language version pub gives
          the package: the lower bound of `environment.sdk`, or "2.7" where
          there is none, as pub's `LanguageVersion.fromSdkConstraint` has it.
        - `unsatisfied`: of the dependencies in `locked_versions`, those whose
          constraint excludes that version, each with the constraint.
        - `fields`: the whole document as JSON values (dicts, lists, strings,
          numbers, booleans, None), for fields pub's checks do not cover, such
          as Flutter's `flutter:` block.
    """
    result = run_pubspec_reader(rctx, pubspec, package_name, locked_versions)
    if not result.refused:
        return result
    if package_name == None:
        what = "{} in @{}".format(pubspec, rctx.original_name)
    else:
        what = "the pubspec of pub package \"{}\"{} (@{})".format(
            package_name,
            " " + version if version else "",
            rctx.original_name,
        )
    return struct(error = "pub would refuse {}:\n{}".format(what, result.error), pubspec = None)
