"""What stands for a part of a Dart SDK that cannot be had, so that only its users fail.

A repository that cannot serve this host or these inputs still fetches, so that
`bazel fetch --all` and `bazel vendor` succeed. What it lacks says why in one of
two ways, by when the lack matters:

* `dart_sdk_error` fails when analyzed, for what a build cannot be analyzed
  without: the SDK itself.
* `dart_sdk_tool_error` analyzes, and fails when its tool is built, for a tool
  that toolchains name but only some actions run. `fail_when_built` is the same
  for any other output.

Nothing here writes a message where a build expects a result.
"""

load("//dart/private:common.bzl", "SDK_ENV")

# Generated repositories load it.
visibility("public")

_DART_TOOLCHAIN = Label("//dart:toolchain_type")

def _dart_sdk_error_impl(ctx):
    fail(ctx.attr.message)

dart_sdk_error = rule(
    implementation = _dart_sdk_error_impl,
    doc = "Fails with `message` when analyzed: only a build that uses this target sees it.",
    attrs = {
        "message": attr.string(doc = "What is wrong, and the fix.", mandatory = True),
    },
)

def fail_when_built(ctx, sdk, outputs, message):
    """Declares `outputs` as the outputs of an action that fails with `message`.

    The action runs a program on the SDK's `dart`, which needs no shell on any
    host. A target of the rule is analyzed as usual, and only a build that asks
    for one of `outputs` fails.

    Args:
        ctx: The rule's context; the rule has the Dart toolchain.
        sdk: The `DartSdkInfo` to run it with.
        outputs: The files that cannot be made.
        message: What is wrong, and the fix.
    """
    program = ctx.actions.declare_file(outputs[0].basename + ".unavailable.dart", sibling = outputs[0])

    # A JSON string is a Dart string, but for interpolation.
    ctx.actions.write(program, """\
import 'dart:io';

void main() {
  stderr.writeln(%s);
  exit(1);
}
""" % json.encode(message).replace("$", "\\$"))
    ctx.actions.run(
        executable = sdk.dart,
        arguments = [program.path],
        inputs = depset([program], transitive = [sdk.files.all]),
        outputs = outputs,
        mnemonic = "DartUnavailable",
        toolchain = _DART_TOOLCHAIN,
        progress_message = "Stopping at what %{label} lacks",
        env = SDK_ENV,
    )

def _dart_sdk_tool_error_impl(ctx):
    tool = ctx.actions.declare_file(ctx.label.name)
    fail_when_built(ctx, ctx.toolchains[_DART_TOOLCHAIN].dart_sdk_info, [tool], ctx.attr.message)
    return [DefaultInfo(executable = tool)]

dart_sdk_tool_error = rule(
    implementation = _dart_sdk_tool_error_impl,
    doc = "A tool that cannot be had: analyzes, and building it fails with `message`, so only an action running it stops the build.",
    attrs = {
        "message": attr.string(doc = "What is wrong, and the fix.", mandatory = True),
    },
    executable = True,
    toolchains = [_DART_TOOLCHAIN],
)
