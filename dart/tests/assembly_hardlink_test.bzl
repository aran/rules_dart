"""Source assembly never hardlinks a file.

bazel_lib's `copy_to_directory` hardlinks, by default, every input that is not
a source file. A generated symlink to a source file is such an input, and
hardlinking it links the source itself: Bazel then makes the output tree
read-only, and the user's file goes from `644` with one link to `555` with
two. It happens only where the output base is on the same disk as the sources,
so no test of the result can be relied on to see it. These tests pin the
configuration of every assembly action instead: not one file is marked for a
hardlink.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "assemble_source_dir", "colocate_packages")

def _symlinked_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = out, target_file = ctx.file.src)
    return [DefaultInfo(files = depset([out]))]

symlinked = rule(
    implementation = _symlinked_impl,
    attrs = {
        "out": attr.string(mandatory = True),
        "src": attr.label(allow_single_file = True, mandatory = True),
    },
    doc = "A generated symlink to a source file, as a rule that exposes a source under another path declares.",
)

def _assembly_probe_impl(ctx):
    # The shapes of assembly in `source_set.bzl` and `project_staging.bzl`:
    # a package's own directory, a whole workspace (`root_paths = []`) with
    # external repositories, and a path remapped by prefix.
    files = ctx.files.srcs
    outs = [
        assemble_source_dir(ctx, ctx.label.name + ".package", files, root_paths = ["."]),
        assemble_source_dir(
            ctx,
            ctx.label.name + ".workspace",
            files,
            root_paths = [],
            include_external_repositories = ["*"],
        ),
        assemble_source_dir(
            ctx,
            ctx.label.name + ".remapped",
            files,
            root_paths = [],
            replace_prefixes = {ctx.label.package: "remapped"},
        ),
    ]
    _, colocated = colocate_packages(
        ctx,
        collect_packages(ctx.attr.deps),
        collect_transitive_srcs(ctx.attr.deps).to_list(),
    )
    return [DefaultInfo(files = depset(outs + colocated))]

assembly_probe = rule(
    implementation = _assembly_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "srcs": attr.label_list(allow_files = True),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Assembles its `srcs` every way rules_dart assembles sources, and its `deps` as a consumer's `colocate_packages` does.",
)

def _never_hardlinks_test_impl(ctx):
    env = analysistest.begin(ctx)
    configs = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith("_config.json")
    ]

    # Three direct assemblies and the one package `colocate_packages` builds.
    asserts.equals(env, 4, len(configs), "assembly actions")
    for config in configs:
        files = json.decode(config.content)["files"]
        asserts.true(env, files, "%s lists no files" % config.outputs.to_list()[0].path)
        for f in files:
            asserts.false(
                env,
                f["hardlink"],
                "%s hardlinks %s" % (config.outputs.to_list()[0].path, f["path"]),
            )
    return analysistest.end(env)

never_hardlinks_test = analysistest.make(_never_hardlinks_test_impl)
