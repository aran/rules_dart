"""Runs a test under another Dart SDK, as `--@rules_dart//dart:sdk` would choose it."""

def _sdk_transition_impl(_settings, attr):
    return {"@rules_dart//dart:sdk": attr.sdk}

_sdk_transition = transition(
    implementation = _sdk_transition_impl,
    inputs = [],
    outputs = ["@rules_dart//dart:sdk"],
)

def _with_sdk_test_impl(ctx):
    test = ctx.attr.test[0]
    executable = test[DefaultInfo].files_to_run.executable
    extension = "." + executable.extension if executable.extension else ""
    link = ctx.actions.declare_file(ctx.label.name + extension)
    ctx.actions.symlink(output = link, target_file = executable, is_executable = True)

    # A `dart_test`'s launcher reads the configuration beside it, by its name.
    links = [link]
    configuration = executable.basename + ".launcher.json"
    for file in test[DefaultInfo].default_runfiles.files.to_list():
        if file.basename == configuration:
            links.append(ctx.actions.declare_file(link.basename + ".launcher.json"))
            ctx.actions.symlink(output = links[-1], target_file = file)
    providers = [DefaultInfo(
        executable = link,
        runfiles = ctx.runfiles(files = links).merge(test[DefaultInfo].default_runfiles),
    )]
    if RunEnvironmentInfo in test:
        providers.append(test[RunEnvironmentInfo])
    return providers

with_sdk_test = rule(
    implementation = _with_sdk_test_impl,
    attrs = {
        "sdk": attr.string(mandatory = True),
        "test": attr.label(mandatory = True, cfg = _sdk_transition, executable = True),
    },
    test = True,
)
