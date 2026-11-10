"""`outline_guard_modules`: kernel modules built several ways, for `outline_guard_test`.

The modules of `dependents` (and everything they depend on) are built with
`--@rules_dart//dart:outline_kernel` off and on: on, every module is compiled
against its dependencies' outlines, and each must be byte-identical to the one
compiled against full kernels.

The modules of `unchanged` and `changed` are built from the fixture's `base`
sources and from each edited variant (`:variant`), with outlines on. Their
full modules must differ, so the edit is real; the outlines of `unchanged`
must not, and those of `changed` (a file declaring mixins, whose positions
dependents copy) must when the edit moves code (`shifted`), and must not when
it does not (`same_length`).
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("//dart:providers.bzl", "DartModuleInfo")
load("//dart/private:dart_module.bzl", "vm_module_aspect")

_OUTLINE = str(Label("//dart:outline_kernel"))
_VARIANT = str(Label("//dart/tests/outline_fixture:variant"))
_EDITS = ["shifted", "same_length"]

VARIANTS = ["base"] + _EDITS

def variant_source(name, out):
    """`out`, copied from `variants/<stem>.<variant>.dart` for the `:variant` flag's value.

    Args:
      name: The target name.
      out: The library file to write, e.g. `lib/ffi.dart`.
    """
    stem = out.rsplit("/", 1)[-1].removesuffix(".dart")
    copy_file(
        name = name,
        src = select({
            "//dart/tests/outline_fixture:%s" % v: "variants/%s.%s.dart" % (stem, v)
            for v in VARIANTS
        }),
        out = out,
    )

def _configs_impl(_settings, _attr):
    configs = {
        "full": {_OUTLINE: False, _VARIANT: "base"},
        "base": {_OUTLINE: True, _VARIANT: "base"},
    }
    for edit in _EDITS:
        configs[edit] = {_OUTLINE: True, _VARIANT: edit}
    return configs

_configs = transition(
    implementation = _configs_impl,
    inputs = [],
    outputs = [_OUTLINE, _VARIANT],
)

def _own(target):
    # The target's own directories: the last of each postorder depset.
    info = target[DartModuleInfo]
    return struct(modules = info.modules.to_list()[-1], outlines = info.outlines.to_list()[-1])

def _impl(ctx):
    placed = {}

    # Every configuration's copy of a directory has the same runfiles path, so
    # each is linked under a path of its own, by which the plan names it.
    def place(config, tree):
        key = (config, tree.path)
        if key not in placed:
            link = ctx.actions.declare_directory("%s/%s/%s" % (ctx.label.name, config, tree.short_path))
            ctx.actions.symlink(output = link, target_file = tree)
            placed[key] = link
        return ctx.workspace_name + "/" + placed[key].short_path

    identical = []
    for full, outlined in zip(ctx.split_attr.dependents["full"], ctx.split_attr.dependents["base"]):
        a = full[DartModuleInfo]
        b = outlined[DartModuleInfo]
        if a.outlines.to_list() != a.modules.to_list():
            fail("%s: outlines with --@rules_dart//dart:outline_kernel off" % full.label)
        if [f.basename for f in b.outlines.to_list()] == [f.basename for f in b.modules.to_list()]:
            fail("%s: no outlines with --@rules_dart//dart:outline_kernel on" % full.label)
        for x, y in zip(a.modules.to_list(), b.modules.to_list()):
            identical.append([place("full", x), place("base", y)])

    edits = []
    for edit in _EDITS:
        for attr, expected in [("unchanged", False), ("changed", True)]:
            split = getattr(ctx.split_attr, attr)
            for base, edited in zip(split["base"], split[edit]):
                before = _own(base)
                after = _own(edited)
                edits.append({
                    "label": "%s (%s)" % (base.label, edit),
                    "modules": [place("base", before.modules), place(edit, after.modules)],
                    "outlines": [place("base", before.outlines), place(edit, after.outlines)],
                    "outline_changes": expected and edit == "shifted",
                })

    plan = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(plan, json.encode_indent({"identical": identical, "edits": edits}))
    return [DefaultInfo(files = depset([plan]), runfiles = ctx.runfiles(files = [plan] + placed.values()))]

def _split(doc):
    return attr.label_list(cfg = _configs, aspects = [vm_module_aspect], doc = doc)

outline_guard_modules = rule(
    implementation = _impl,
    attrs = {
        "dependents": _split("Libraries whose modules must not depend on whether they were compiled against outlines."),
        "unchanged": _split("Libraries whose outlines the edited variants leave unchanged."),
        "changed": _split("Libraries whose outlines the edited variants change."),
    },
)
