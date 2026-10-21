"""A library rule whose Dart dependency comes from a toolchain, as `dart_proto_library`'s protobuf runtime does."""

load("//dart:providers.bzl", "DartInfo")
load("//dart:utils.bzl", "DART_TOOLCHAIN_TYPES_ATTR", "dart_info")

_TOOLCHAIN_TYPE = "//dart/tests/toolchain_dep_fixture:toolchain_type"

def _runtime_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(runtime = ctx.attr.runtime)]

runtime_toolchain = rule(
    implementation = _runtime_toolchain_impl,
    attrs = {"runtime": attr.label(providers = [DartInfo])},
)

def _library_impl(ctx):
    runtime = ctx.toolchains[_TOOLCHAIN_TYPE].runtime
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        dart_info(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            language_version = "3.11",
            deps = [runtime],
            srcs = ctx.files.srcs,
            # Its sources import the package the runtime is built on, as
            # generated code does, found by package in the runtime's own deps.
            indirect_deps = [dep for dep, package in runtime[DartInfo].deps.items() if package == "toolchain_inner"],
        ),
    ]

library_with_toolchain_runtime = rule(
    implementation = _library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "package_name": attr.string(mandatory = True),
        DART_TOOLCHAIN_TYPES_ATTR: attr.label_list(default = [_TOOLCHAIN_TYPE]),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)
