# A .bzl file whose public symbols are documented in part, for
# //tool:starlark_docs_test. It has no module docstring on purpose.

# buildifier: disable=module-docstring
def _impl(_ctx):
    pass

documented_rule = rule(
    implementation = _impl,
    doc = "Collects Dart sources — it's a \"library\".",
    attrs = {
        "srcs": attr.label_list(doc = "The sources."),
        "deps": attr.label_list(),
    },
)

undocumented_macro = macro(
    implementation = _impl,
    attrs = {"opt": attr.string(doc = "An option.")},
)

DocumentedInfo = provider(
    doc = "Carries sources.",
    fields = {
        "srcs": "The sources.",
        "deps": "",
    },
)

# buildifier: disable=function-docstring-args
def documented_function(ctx, **kwargs):
    """Builds a thing.

    Args:
        ctx: The rule context.
    """
    return (ctx, kwargs)

documented_aspect = aspect(
    implementation = _impl,
    doc = "Walks deps.",
    attrs = {"mode": attr.string(values = ["a"])},
)

undocumented_repository_rule = repository_rule(
    implementation = _impl,
    attrs = {"url": attr.string(doc = "Where from.")},
)

documented_extension = module_extension(
    implementation = _impl,
    doc = "Fetches packages.",
    tag_classes = {
        "package": tag_class(attrs = {"sha256": attr.string(doc = "The digest.")}),
    },
)
