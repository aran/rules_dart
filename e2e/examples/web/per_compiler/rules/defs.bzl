"""Rules this module defines over rules_dart's web compiler setting.

They stand in for what other rule sets build: a native module built by another
toolchain (rules_flutter's `flutter_native_library`, frustrate's Rust wasm
module), a library rule that wraps both pub packages and first-party code
(rules_flutter's `flutter_library`), and a web bundle that compiles one app for
several compilers through a split transition (`flutter_web_application`).
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "PORTABLE_EXEC_GROUPS",
    "RUNTIME_INDEPENDENT_ATTR",
    "SUMMARY_ATTRS",
    "collect_packages",
    "collect_transitive_srcs",
    "colocate_packages",
    "dart_info",
    "derive_package_root",
    "non_dart_transition",
    "runtime_reset_when_independent",
    "web_platforms_transition",
)

NativeModuleInfo = provider(
    doc = "A native module and those of the libraries beneath.",
    fields = {"modules": "depset[File]"},
)

def _native_module_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".bin")
    ctx.actions.write(out, "native module " + ctx.label.name)
    return [
        DefaultInfo(files = depset([out])),
        NativeModuleInfo(modules = depset([out])),
    ]

# Nothing of it is compiled Dart, so its output cannot depend on the web
# compiler, on creation-location tracking or on an executable's environment,
# and every route into it reaches one configured target, built once.
native_module = rule(
    implementation = _native_module_impl,
    cfg = non_dart_transition,
)

def _module_library_impl(ctx):
    return [
        dart_info(
            ctx = ctx,
            packages = [DartPackageInfo(
                label = ctx.label,
                package_name = ctx.attr.package_name,
                package_root = derive_package_root(ctx.label.workspace_root, ctx.label.package),
                language_version = "",
            )],
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
        ),
        NativeModuleInfo(modules = depset(transitive = [
            m[NativeModuleInfo].modules
            for m in ctx.attr.modules + ctx.attr.deps
            if NativeModuleInfo in m
        ])),
    ]

# A Dart library with native modules. Some of its targets are pub packages and
# some first-party code, so it resets only the ones that say they may.
module_library = rule(
    implementation = _module_library_impl,
    cfg = runtime_reset_when_independent,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo]),
        "modules": attr.label_list(providers = [NativeModuleInfo]),
        "package_name": attr.string(mandatory = True),
    } | RUNTIME_INDEPENDENT_ATTR | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

# The web platforms a rule set compiling one app for several compilers
# builds each branch for: an attribute, so the branches are computed from it.
WEB_PLATFORMS_ATTR = {
    "web_platforms": attr.label_list(default = [
        "@rules_dart//dart/platforms:js",
        "@rules_dart//dart/platforms:wasm",
    ]),
}

def _branch_sources_impl(ctx):
    # One branch's staging. Configured once per compiler under `web_bundle`,
    # so the assembled directories (`<name>.<package>.pkgsrcs`) each land in
    # their own branch's output directory.
    _, srcs = colocate_packages(
        ctx,
        collect_packages(ctx.attr.deps),
        collect_transitive_srcs(ctx.attr.deps).to_list(),
    )
    assembled = [f for f in srcs if f.is_directory]
    if not assembled:
        fail("%s: expected a package with generated sources to be assembled" % ctx.label)
    return [DefaultInfo(files = depset(assembled))]

branch_sources = rule(
    implementation = _branch_sources_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])},
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

def _web_bundle_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.split_attr.branch.values()
    ]))]

# Builds `branch` once per compiler.
web_bundle = rule(
    implementation = _web_bundle_impl,
    attrs = {"branch": attr.label(cfg = web_platforms_transition, mandatory = True)} | WEB_PLATFORMS_ATTR,
)
