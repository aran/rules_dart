"""Reads a pubspec.yaml in a repository rule, as pub reads it.

`read_pubspec` runs rules_dart's pubspec reader: Dart's own `package:yaml`,
the loader pub uses, compiled once per host. The file is read exactly as pub
reads it, and refused where pub refuses it, with pub's message, naming the
package. Any repository rule can call it, in any module: rules_dart's pub
repositories do, for hosted packages and for packages fetched another way.
"""

load("//dart/pub/private/pubspec_reader:reader.bzl", "run_pubspec_reader")

def read_pubspec(rctx, package_name, version = "", pubspec = "pubspec.yaml"):
    """Reads a package's pubspec, failing where pub would.

    pub's checks apply to the fields this returns: `name` must be the package's,
    each dependency must be named and specified as pub requires, and every
    version constraint, `environment.sdk` among them, must be a string.

    Args:
        rctx: The `repository_ctx`.
        package_name: The name the package is fetched as, which the pubspec's
            `name` must match, as pub requires; None to take any valid name,
            for a pubspec read for itself rather than as a package's.
        version: The package's version, for messages; empty for none.
        pubspec: The pubspec's path, relative to the repository.

    Returns:
        `struct`:
        - `name`: the `name` field.
        - `dependencies`: the names under `dependencies:`, in order.
        - `sdk_constraint`: `environment.sdk`, or "" for none.
        - `language_version`: the `<major>.<minor>` language version pub gives
          the package: the lower bound of `environment.sdk`, or "2.7" where
          there is none, as pub's `LanguageVersion.fromSdkConstraint` has it.
        - `fields`: the whole document as JSON values (dicts, lists, strings,
          numbers, booleans, None), for fields pub's checks do not cover, such
          as Flutter's `flutter:` block.
    """
    result = run_pubspec_reader(rctx, pubspec, package_name)
    if result.error == None:
        return result.pubspec
    if package_name == None:
        what = "{} in @{}".format(pubspec, rctx.original_name)
    else:
        what = "the pubspec of pub package \"{}\"{} (@{})".format(
            package_name,
            " " + version if version else "",
            rctx.original_name,
        )
    fail("pub would refuse {}:\n{}".format(what, result.error))
