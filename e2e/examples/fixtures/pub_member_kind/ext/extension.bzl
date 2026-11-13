"""The repositories of a downstream pub extension, planned with rules_dart's helpers.

Each package is a source repository (`fancy_src__<name>`), holding its member
and the names its pubspec depends on, and a library repository
(`fancy__<name>`), which reads those names for every package it reaches and
builds the package's dependency cycle as one `fancy_library` in the cycle
owner's repository; the other packages of the cycle alias it. A cycle is
declared with `fancy.cycle()`, as `pub.cycle()` declares one.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_cycles")
load("@rules_dart//dart/pub:pub_graph.bzl", "cycle_declarations_error", "dependency_cycle", "dependency_graph", "read_pubspec_dependencies", "write_pubspec_dependencies")
load("@rules_dart//dart/pub:pubspec.bzl", "read_pubspec")

def _source(name):
    return "fancy_src__" + name

def _library(name):
    return "fancy__" + name

_RULES = str(Label("//fixtures/pub_member_kind/ext:rules.bzl"))

# The package's `dart_package_metadata`. Not a Dart package name, so never the
# name of the member beside it, which is named for its package.
_METADATA_TARGET = "fancy-metadata"
_PUB_LIBRARY = str(Label("@rules_dart//dart/pub:pub_library.bzl"))

_FILES = """\
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
    resources = glob(["lib/**"], exclude = ["lib/**/*.dart"], allow_empty = True),
    package = ":{metadata}",
"""

_METADATA = """\
dart_package_metadata(
    name = "{metadata}",
    package_name = "{name}",
    language_version = "{language_version}",
)

"""

def _fancy_source_impl(ctx):
    pubspec = ctx.path(ctx.attr.pubspec)
    ctx.symlink(pubspec.dirname.get_child("lib"), "lib")
    ctx.symlink(pubspec, "pubspec.yaml")
    read = read_pubspec(ctx, ctx.attr.package_name)
    write_pubspec_dependencies(ctx, read.dependencies)
    metadata = _METADATA.format(
        metadata = _METADATA_TARGET,
        name = ctx.attr.package_name,
        language_version = read.language_version,
    )
    if ctx.attr.greeting:
        build = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\nload("{rules}", "fancy_member")\n\n{metadata}fancy_member(\n    name = "{name}",\n{files}    greeting = "{greeting}",\n    visibility = ["//visibility:public"],\n)\n'.format(
            rules = _RULES,
            name = ctx.attr.package_name,
            metadata = metadata,
            files = _FILES.format(metadata = _METADATA_TARGET),
            greeting = ctx.attr.greeting,
        )
    else:
        build = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\nload("{rules}", "pub_package_member")\n\n{metadata}pub_package_member(\n    name = "{name}",\n{files}    visibility = ["//visibility:public"],\n)\n'.format(
            rules = _PUB_LIBRARY,
            name = ctx.attr.package_name,
            metadata = metadata,
            files = _FILES.format(metadata = _METADATA_TARGET),
        )
    ctx.file("BUILD.bazel", build)

_fancy_source = repository_rule(
    implementation = _fancy_source_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "pubspec": attr.label(mandatory = True, allow_single_file = True),
        "greeting": attr.string(),
    },
)

def _labels(names, suffix = ""):
    return "[{}]".format(", ".join(['"@{}//:{}{}"'.format(_library(n), n, suffix) for n in names]))

def _fancy_library_repo_impl(ctx):
    name = ctx.attr.package_name
    known = {p: True for p in ctx.attr.packages}
    graph = dependency_graph(
        name,
        lambda p: [d for d in read_pubspec_dependencies(ctx, _source(p)) if d in known],
        follow = known,
    )
    cycle = dependency_cycle(
        graph,
        name,
        declared = [c.split(" ") for c in ctx.attr.cycles],
        advisory = [c.split(" ") for c in ctx.attr.advisory_cycles],
        declare = "fancy.cycle",
    )
    if cycle.owner != name:
        ctx.file("BUILD.bazel", """\
alias(name = "{name}", actual = "@{owner_repo}//:{owner}", visibility = ["//visibility:public"])
alias(name = "{name}_native", actual = "@{owner_repo}//:{owner}_native", visibility = ["//visibility:public"])
""".format(name = name, owner = cycle.owner, owner_repo = _library(cycle.owner)))
        return

    # The per-platform library depends on those of what the cycle depends on:
    # `cycle.deps`, the union of its members' dependencies outside it.
    ctx.file("BUILD.bazel", """\
load("{rules}", "fancy_library", "fancy_native")

fancy_library(
    name = "{name}",
    members = {members},
    deps = {deps},
    visibility = ["//visibility:public"],
)

fancy_native(
    name = "{name}_native",
    deps = {native_deps},
    visibility = ["//visibility:public"],
)
""".format(
        rules = _RULES,
        name = name,
        members = "[{}]".format(", ".join(['"@{}//:{}"'.format(_source(m), m) for m in cycle.packages])),
        deps = _labels(cycle.deps),
        native_deps = _labels(cycle.deps, "_native"),
    ))

_fancy_library_repo = repository_rule(
    implementation = _fancy_library_repo_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "packages": attr.string_list(doc = "Every package the extension makes."),
        "cycles": attr.string_list(doc = "The root module's cycles, each its packages joined by spaces."),
        "advisory_cycles": attr.string_list(doc = "Other modules' and the curated cycles, each its packages joined by spaces."),
    },
)

_package = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "pubspec": attr.label(mandatory = True),
    "greeting": attr.string(doc = "Makes the package a `fancy_member`; without one it is rules_dart's `pub_package_member`."),
})

_cycle = tag_class(attrs = {
    "packages": attr.string_list(mandatory = True),
})

def _fancy_impl(mctx):
    tags = [t for mod in mctx.modules for t in mod.tags.package]
    names = [t.name for t in tags]
    declared = []
    advisory = [" ".join(c) for c in curated_cycles()]
    for mod in mctx.modules:
        groups = [sorted(t.packages) for t in mod.tags.cycle]
        error = cycle_declarations_error(groups, "the root module" if mod.is_root else "module `%s`" % mod.name, "fancy.cycle")
        if error:
            fail(error)
        (declared if mod.is_root else advisory).extend([" ".join(g) for g in groups])
    for t in tags:
        _fancy_source(name = _source(t.name), package_name = t.name, pubspec = t.pubspec, greeting = t.greeting)
        _fancy_library_repo(
            name = _library(t.name),
            package_name = t.name,
            packages = names,
            cycles = declared,
            advisory_cycles = advisory,
        )
    return mctx.extension_metadata(reproducible = True)

fancy = module_extension(
    implementation = _fancy_impl,
    tag_classes = {"cycle": _cycle, "package": _package},
)
