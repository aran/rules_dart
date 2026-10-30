"""The execution group rules_dart's platform-independent actions run in.

A kernel, an import check or a web compile reads and writes the
same bytes whichever host runs it, so it needs only a Dart SDK built for that
host: the exec-tools toolchain, which, unlike `//dart:toolchain_type`, does not
tie the host to the target platform. Such an action runs in `portable`, which
resolves to the first execution platform that has an SDK: a remote Linux
worker when one is registered first, the local machine otherwise. Actions that
produce machine code for the target (`dart compile exe`) stay in the rule's
default group, whose toolchain matches the target.

Every tool such an action runs comes from `config.exec(PORTABLE)`, so it is
built for the same host the action runs on. A named group, unlike the rule's
default group, keeps its toolchain under `--incompatible_auto_exec_groups`, so
tool and SDK agree with the flag on or off.
"""

PORTABLE = "portable"

EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

PORTABLE_EXEC_GROUPS = {
    PORTABLE: exec_group(toolchains = [EXEC_TOOLS_TOOLCHAIN]),
}

def portable_sdk(ctx):
    """The `DartSdkInfo` of the host `portable` actions run on.

    Args:
      ctx: A rule or aspect context declaring `PORTABLE_EXEC_GROUPS`.

    Returns:
      The `DartSdkInfo`.
    """
    return ctx.exec_groups[PORTABLE].toolchains[EXEC_TOOLS_TOOLCHAIN].dart_sdk_info
