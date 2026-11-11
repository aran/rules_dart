"""`@rules_dart//dart/pub`: pub, from the toolchain's Dart SDK.

The executable is `pub_runner.dart` compiled by one `dart compile exe` action
on the toolchain's SDK, with no Dart tool rules_dart builds itself: those are
built from pub packages the `pub` extension supplies, and the runner has to
work while that extension refuses a lock. It finds the SDK's `dart` through
its runfiles and runs `dart pub` at the workspace root.
"""

load("//dart:utils.bzl", "dart_compile_action", "runfiles_path")

visibility("//dart/...")

def _pub_runner_impl(ctx):
    sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    dart_compile_action(
        ctx = ctx,
        sdk = sdk,
        kernel = ctx.file.main,
        sources = depset(ctx.files.srcs + [ctx.file.main]),
        output = executable,
        extra_flags = ["-Drules_dart.pub.dart=" + runfiles_path(sdk.dart, ctx.workspace_name)],
    )
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(transitive_files = sdk.files.run),
    )]

pub_runner = rule(
    implementation = _pub_runner_impl,
    attrs = {
        "main": attr.label(
            doc = "The runner's entry point, importing only `dart:` libraries and `srcs`.",
            allow_single_file = [".dart"],
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "The Dart files `main` imports by relative path.",
            allow_files = [".dart"],
        ),
        "_os_windows": attr.label(default = "@platforms//os:windows"),
    },
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs `dart pub` with the toolchain's SDK at the root of the workspace `bazel run` was started in.",
)
