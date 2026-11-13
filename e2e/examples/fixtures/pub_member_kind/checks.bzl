"""Analysis-time assertions about a downstream pub library.

`member_kind_check` fails analysis (so `bazel build //...` fails) when a
target it names does not carry what the assertion states. Building it is the
test.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//fixtures/pub_member_kind/ext:rules.bzl", "FancyInfo")

def _names(packages):
    return sorted([p.package_name for p in packages])

def _impl(ctx):
    problems = []
    if len(ctx.attr.targets) != len(ctx.attr.natives_of):
        fail("`targets` and `natives_of` pair up")
    for target, native in zip(ctx.attr.targets, ctx.attr.natives_of):
        _check(ctx, target, native, problems)
    if problems:
        fail("\n".join(problems))

    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

def _check(ctx, target, native, problems):
    label = str(target.label)
    info = target[DartInfo]
    analyzable = target[DartAnalyzableInfo].dart_info
    fancy = target[FancyInfo]
    direct = sorted({n: True for names in info.deps.values() for n in names}.keys())
    natives = sorted([f.basename for f in native[DefaultInfo].files.to_list()])

    def expect(what, want, got):
        if want != got:
            problems.append("%s: %s is %s, expected %s" % (label, what, got, want))

    expect("DartInfo.packages", sorted(ctx.attr.packages), _names(info.packages))
    expect("the packages its direct deps contribute", sorted(ctx.attr.direct_deps), direct)
    expect("DartInfo.transitive_packages", sorted(ctx.attr.transitive_packages), _names(info.transitive_packages.to_list()))
    expect("DartAnalyzableInfo's packages", sorted(ctx.attr.packages), _names(analyzable.packages))
    expect(
        "DartAnalyzableInfo's transitive packages",
        sorted(ctx.attr.transitive_packages + ctx.attr.analyzer_only_packages),
        _names(analyzable.transitive_packages.to_list()),
    )
    expect("FancyInfo.greetings", ctx.attr.greetings, fancy.greetings)
    expect("FancyInfo.transitive_greetings", sorted(ctx.attr.transitive_greetings), sorted(fancy.transitive_greetings.to_list()))
    expect("its native library's closure", sorted(ctx.attr.natives), natives)

member_kind_check = rule(
    implementation = _impl,
    attrs = {
        "targets": attr.label_list(mandatory = True, providers = [DartInfo, DartAnalyzableInfo, FancyInfo], doc = "Libraries that must all carry what the other attributes state."),
        "natives_of": attr.label_list(mandatory = True, doc = "Each target's per-platform library, in order."),
        "packages": attr.string_list(doc = "The packages the target contributes itself."),
        "direct_deps": attr.string_list(doc = "The packages its direct dependencies contribute."),
        "transitive_packages": attr.string_list(doc = "Every package of its compile closure."),
        "analyzer_only_packages": attr.string_list(doc = "Packages only its analysis closure adds."),
        "greetings": attr.string_dict(doc = "Its own members' greetings."),
        "transitive_greetings": attr.string_list(doc = "`<package>=<greeting>` for it and every library beneath."),
        "natives": attr.string_list(doc = "Basenames of its native library's closure."),
    },
)
