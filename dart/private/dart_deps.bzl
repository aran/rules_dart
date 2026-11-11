"""Following a `DartInfo` target's direct dependencies, for the aspects that walk them.

Which attribute a dependency arrives through is the rule's business —
`dart_library` uses `deps`, `dart_proto_library` keeps its Dart deps in
`dart_deps` and takes its runtime from a toolchain, a forwarder such as
`dart_test_package` passes on a `library` — so an aspect follows every
attribute that is not a tool, plus the toolchains a rule lists in
`DART_TOOLCHAIN_TYPES_ATTR`, and picks the dependencies out by
`DartInfo.deps`, what the rule passed to `dart_info()`. A target reached that
has no `DartInfo` (a toolchain, or an executable-like wrapper
with only `DartAnalyzableInfo`) hands on the libraries it holds, one hop, in its
provider's `exported`.
"""

load("//dart:providers.bzl", "DartInfo")

visibility("//dart/...")

# A rule whose `DartInfo` dependencies come from a toolchain rather than an
# attribute (`dart_proto_library`'s protobuf runtime) names the toolchain types
# in a private `label_list` of this name, so the aspects reach them too.
DART_TOOLCHAIN_TYPES_ATTR = "_dart_toolchain_types"

def propagated_attrs(ctx):
    """`attr_aspects`: every attribute but tools and the toolchain list."""
    return [
        name
        for name in dir(ctx.rule.attr)
        if name != DART_TOOLCHAIN_TYPES_ATTR and not getattr(ctx.rule.attr, name).is_tool
    ]

def propagated_toolchains(ctx):
    """`toolchains_aspects`: the toolchain types the rule lists."""
    types = getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, None)
    return list(types.value) if types != None else []

def reached_targets(ctx, provider):
    """Every target the aspect reached from this one carrying `provider`.

    Args:
      ctx: The aspect context.
      provider: The aspect's provider.

    Returns:
      The list of reached Targets, from attributes and listed toolchains.
    """
    reached = []
    for name in dir(ctx.rule.attr):
        if name == DART_TOOLCHAIN_TYPES_ATTR:
            continue
        value = getattr(ctx.rule.attr, name)
        if type(value) == "dict":
            value = value.keys()
        elif type(value) != "list":
            value = [value]
        for dep in value:
            if type(dep) == "Target" and provider in dep:
                reached.append(dep)
    for toolchain_type in getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, []):
        toolchain = ctx.rule.toolchains[toolchain_type.label]
        if toolchain != None and provider in toolchain:
            reached.append(toolchain)
    return reached

def exported_libraries(reached):
    """For a target that is not a library: the libraries it holds, by label."""
    return {dep.label: dep for dep in reached if DartInfo in dep}

def forwarded_library(info, reached):
    """The dependency whose `DartInfo` this target passes on unchanged, or `None`.

    `dart_test_package` hands on `package:test`'s library; such a target has
    nothing of its own to compile or check.

    Args:
      info: The target's `DartInfo`.
      reached: `reached_targets(ctx, provider)`.

    Returns:
      The forwarded dependency Target, or `None`.
    """
    for dep in reached:
        if DartInfo in dep and dep[DartInfo].srcs == info.srcs and dep[DartInfo].packages == info.packages:
            return dep
    return None

def direct_dart_deps(ctx, info, reached, provider):
    """The targets `info` depends on directly, as reached by the aspect.

    Args:
      ctx: The aspect context.
      info: The target's `DartInfo`.
      reached: `reached_targets(ctx, provider)`.
      provider: The aspect's provider, whose `exported` a non-library carries.

    Returns:
      The list of dependency Targets, each with `DartInfo` and `provider`.
    """
    by_label = {}
    for dep in reached:
        if DartInfo in dep:
            by_label[dep.label] = dep
    for dep in reached:
        for label, exported in getattr(dep[provider], "exported", {}).items():
            by_label.setdefault(label, exported)

    # `getattr`: a provider built before `deps` existed names none; every
    # library reached stands in for it.
    wanted = getattr(info, "deps", None)
    if wanted == None:
        return [dep for dep in reached if DartInfo in dep]
    missing = [label for label in wanted if label not in by_label]
    if missing:
        fail(("%s: depends on %s, but the aspect cannot reach %s through any " +
              "attribute. A dependency taken from a toolchain is reached only if " +
              "the rule lists the toolchain type in `%s`.") %
             (ctx.label, missing[0], "it" if len(missing) == 1 else "them", DART_TOOLCHAIN_TYPES_ATTR))
    return [by_label[label] for label in wanted]
