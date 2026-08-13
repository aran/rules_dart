"""Implementation of the dart_analysis_options rule.

An `analysis_options.yaml` is not always self-contained. The published way to
share a lint ruleset is to depend on a pub package and `include` its yaml by
`package:` URI:

    include: package:very_good_analysis/analysis_options.yaml

The analyzer resolves that URI through the *project's* `package_config.json`,
exactly as it resolves an import. So an options file is not merely a file — it
can carry package dependencies, and whether it loads depends on the package
closure of whatever project it is applied to.

Passing a bare `.yaml` label leaves no way to express that, and the only way to
make the include resolve is to add the ruleset to the analyzed library's own
`deps`. That works and is wrong: a lint ruleset then rides in the library's
`DartInfo`, so every `dart_binary` and `dart_test` downstream stages sources it
will never compile, and the package_config of unrelated targets grows an entry
that exists only to satisfy a linter.

This rule keeps the file and the packages its includes resolve against together
in one target, so `dart_analyze_test` can stage that closure for options
resolution alone. The packages land in the non-analyzed `extpkgs` region beside
pub sources — resolvable, never themselves analyzed — and never reach the
analyzed target's own provider.
"""

load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_resources", "collect_transitive_srcs")

def _dart_analysis_options_impl(ctx):
    return [
        # A single file, so this target is still usable anywhere a plain
        # `analysis_options.yaml` label was: `allow_single_file` is satisfied
        # and the file-only path through `dart_analyze_test` keeps working.
        DefaultInfo(files = depset([ctx.file.src])),
        DartAnalysisOptionsInfo(
            file = ctx.file.src,
            packages = collect_packages(ctx.attr.deps),
            transitive_srcs = collect_transitive_srcs(ctx.attr.deps),
            transitive_resources = collect_transitive_resources(ctx.attr.deps),
        ),
    ]

dart_analysis_options = rule(
    implementation = _dart_analysis_options_impl,
    attrs = {
        "src": attr.label(
            doc = "The `analysis_options.yaml` file.",
            mandatory = True,
            allow_single_file = [".yaml"],
        ),
        "deps": attr.label_list(
            doc = (
                "Dart packages whose files this options file `include`s by " +
                "`package:` URI. Staged for resolution only — these are not " +
                "analyzed, and do not become dependencies of the analyzed " +
                "library."
            ),
            providers = [DartInfo],
        ),
    },
    doc = (
        "An `analysis_options.yaml` bundled with the packages its `include:` " +
        "directives resolve against, for use as `dart_analyze_test`'s " +
        "`options`."
    ),
)
