"""The `dart_package` rule: one declaration of a Dart package's identity."""

load("//dart:providers.bzl", "DartPackageIdentityInfo")

def _dart_package_impl(ctx):
    return [DartPackageIdentityInfo(
        package_name = ctx.attr.package_name,
        language_version = ctx.attr.language_version,
    )]

dart_package = rule(
    implementation = _dart_package_impl,
    attrs = {
        "package_name": attr.string(
            mandatory = True,
            doc = "The Dart package name used in `package:` imports — the `name:` from the package's `pubspec.yaml`.",
        ),
        "language_version": attr.string(
            doc = "Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form (e.g. `3.11`). Emitted as `languageVersion` in generated `package_config.json` entries and passed to code generators as the root language version. Leave empty to state none.",
        ),
    },
    provides = [DartPackageIdentityInfo],
    doc = """Declares a Dart package's name and language version once, for every rule that builds part of it.

Point `dart_library`, `dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen`
and `dart_format_test` at it with `package = ":<name>"` instead of repeating
`package_name` and `language_version` on each:

```starlark
dart_package(
    name = "pkg",
    package_name = "my_app",
    language_version = "3.11",
)

dart_codegen(
    name = "model_g",
    package = ":pkg",
    src = "lib/model.dart",
    generator = "//tools:gen.dart",
    output_suffixes = [".g.dart"],
)

dart_library(
    name = "my_app",
    package = ":pkg",
    srcs = ["lib/model.dart", ":model_g"],
)
```

A rule takes its identity from `package` or from the inline `package_name` /
`language_version` attributes, never both — setting both fails, so the two can
never drift into disagreeing. The inline attributes remain fully supported and
are still the contract every rule is defined against; they are what generated
spoke repositories emit, where a generator writes both from one value and there
is no duplication to remove. `dart_package` is for hand-written packages, where
there is.

Visible across BUILD files, which is the case a macro cannot reach: a package
whose `dart_library` sits in `app/BUILD.bazel` and whose `dart_codegen` sits in
`gen/BUILD.bazel` has two files stating the same two strings, and only a target
can be referenced from both.

Not to be confused with `pub.package()`, the module extension tag that fetches a
published package from pub.dev. This declares facts about a package you are
building yourself.""",
)
