"""The repositories of a downstream pub extension, planned with rules_dart's helpers.

Each package is a source repository (`fancy_src__<name>`), holding its member
and the names its pubspec depends on, and a library repository
(`fancy__<name>`), which reads those names for every package it reaches and
builds the package's dependency cycle as one `fancy_library` in the cycle
owner's repository; the other packages of the cycle alias it.
"""

load("@rules_dart//dart/pub:pub_graph.bzl", "dependency_cycle", "dependency_graph", "read_pubspec_dependencies", "write_pubspec_dependencies")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("@rules_dart//dart/pub:pubspec.bzl", "read_pubspec")

def _source(name):
    return "fancy_src__" + name

def _library(name):
    return "fancy__" + name

_RULES = str(Label("//ext:rules.bzl"))
_PUB_LIBRARY = str(Label("@rules_dart//dart/pub:pub_library.bzl"))

_FILES = """\
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
    resources = glob(["lib/**"], exclude = ["lib/**/*.dart"], allow_empty = True),
    package_name = "{name}",
    language_version = "{language_version}",
"""

def _fancy_source_impl(ctx):
    pubspec = ctx.path(ctx.attr.pubspec)
    ctx.symlink(pubspec.dirname.get_child("lib"), "lib")
    ctx.symlink(pubspec, "pubspec.yaml")
    read = read_pubspec(ctx, ctx.attr.package_name)
    write_pubspec_dependencies(ctx, read.dependencies)
    files = _FILES.format(
        name = ctx.attr.package_name,
        language_version = derive_language_version(read.sdk_constraint),
    )
    if ctx.attr.greeting:
        build = 'load("{rules}", "fancy_member")\n\nfancy_member(\n    name = "{name}",\n{files}    greeting = "{greeting}",\n    visibility = ["//visibility:public"],\n)\n'.format(
            rules = _RULES,
            name = ctx.attr.package_name,
            files = files,
            greeting = ctx.attr.greeting,
        )
    else:
        build = 'load("{rules}", "pub_package_member")\n\npub_package_member(\n    name = "{name}",\n{files}    visibility = ["//visibility:public"],\n)\n'.format(
            rules = _PUB_LIBRARY,
            name = ctx.attr.package_name,
            files = files,
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
    cycle = dependency_cycle(graph, name)
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
    },
)

_package = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "pubspec": attr.label(mandatory = True),
    "greeting": attr.string(doc = "Makes the package a `fancy_member`; without one it is rules_dart's `pub_package_member`."),
})

def _fancy_impl(mctx):
    tags = [t for mod in mctx.modules for t in mod.tags.package]
    names = [t.name for t in tags]
    for t in tags:
        _fancy_source(name = _source(t.name), package_name = t.name, pubspec = t.pubspec, greeting = t.greeting)
        _fancy_library_repo(name = _library(t.name), package_name = t.name, packages = names)
    return mctx.extension_metadata(reproducible = True)

fancy = module_extension(
    implementation = _fancy_impl,
    tag_classes = {"package": _package},
)
