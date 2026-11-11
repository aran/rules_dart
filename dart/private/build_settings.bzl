"""The `//dart:extra_dart_defines` build setting and its plumbing.

A `defines` attribute pins environment declarations to one target. This flag is
the command-line channel for the same thing: a `.bazelrc` config group can point
an entire build at an environment without editing BUILD files, which is what
makes `--config=staging` reach a binary, its tests, and its probes alike.

Flag values are appended *after* a target's own `defines`, so the command line
wins on a key collision — every Dart compiler takes the last `-D` for a
repeated key.

Unlike rules_flutter's equivalent, no define keys are reserved here. That list
exists there because the Flutter build sets `dart.vm.product` and friends itself
from the compilation mode, and a user value would silently fight it. rules_dart
maps compilation mode to `--enable-asserts` and gen-snapshot options, and sets
only the `dart.vm.*` defines `dart compile` itself sets, ahead of the user's,
so a user value wins as it would under `dart compile`: it has nothing to
protect.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

visibility("//dart/...")

def dart_define_error(define, what):
    """Returns an error string if `define` is not a usable `-D` entry.

    Args:
      define: A define string. Normally `KEY=VALUE`; a bare `KEY` is a key with
        no value, which the Dart compilers accept.
      what: Where the define came from, named in the message — a target label
        or the flag name.

    Returns:
      An error string, or None when the entry is usable.
    """
    if not define:
        return (("Empty Dart define in %s. Entries are `KEY` or `KEY=VALUE`; " +
                 "an empty one becomes a bare `-D`, which the compiler rejects.") %
                what)
    if define.startswith("="):
        return (("Dart define %r in %s has an empty key. " +
                 "Entries are `KEY` or `KEY=VALUE`.") % (define, what))
    return None

def validate_dart_defines(defines, what):
    """Fails on the first unusable define.

    Args:
      defines: List of define strings.
      what: Where they came from, named in any failure message.
    """
    for define in defines:
        err = dart_define_error(define, what)
        if err != None:
            fail(err)

def _dart_defines_flag_impl(ctx):
    validate_dart_defines(ctx.build_setting_value, "--%s" % ctx.label)
    return BuildSettingInfo(value = ctx.build_setting_value)

dart_defines_flag = rule(
    implementation = _dart_defines_flag_impl,
    # `repeatable` so each occurrence contributes one whole list element.
    # skylib's `string_list_flag` splits a value on commas, which would turn
    # `-DA=1,2` into two broken entries before the compiler ever sees it.
    build_setting = config.string_list(flag = True, repeatable = True),
    attrs = {
        # Read by Bazel, as on skylib's flags, and only where a target sets
        # it: `scope = "target"` resets the flag on every exec transition.
        "scope": attr.string(),
    },
    doc = "A repeatable list of Dart environment declarations (`KEY=VALUE`), " +
          "appended after a target's own `defines` so the command line wins " +
          "on a key collision.",
)

EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "The //dart:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//dart:extra_dart_defines"),
    ),
}

def merge_dart_defines(ctx):
    """Merges a target's `defines` attr with the `extra_dart_defines` flag.

    The flag validates its own value in its rule implementation, so only the
    attr is validated here.

    Args:
      ctx: Rule context carrying `defines` and `_extra_dart_defines`.

    Returns:
      The merged list of define strings, flag values last.
    """
    validate_dart_defines(ctx.attr.defines, "the `defines` attribute of %s" % ctx.label)
    return list(ctx.attr.defines) + ctx.attr._extra_dart_defines[BuildSettingInfo].value

def module_define_comma_error(define, source):
    """The error for a define a test's module compile would cut, or `None`.

    `kernel_worker`, which compiles the modules of a `dart_test` and of the
    libraries it depends on, splits every `-D` value on commas, so `-DA=x,y`
    reaches the test as `A=x`, silently. Refused rather than passed on. The
    compiles of a whole program (`frontend_server`, which `dart_binary` uses)
    and of the web (`dart compile js` and `wasm`) keep a value whole.

    Args:
      define: A `KEY=VALUE` string.
      source: Where it came from, for the message.

    Returns:
      An error message, or `None`.
    """
    if "," not in define:
        return None
    return ("`%s` (from %s): a define of a program compiled in modules cannot have a comma in its value. " +
            "Their compiler (`kernel_worker`) splits every `-D` value on commas, so the " +
            "program would see the value cut at the first one. A `dart_binary` accepts a " +
            "comma. Encode the value (base64, say) and decode it in the program.") % (define, source)

TRACK_CREATION_LOCATIONS_ATTR = {
    "_track_creation_locations": attr.label(
        doc = "The //dart:track_creation_locations build setting.",
        default = Label("//dart:track_creation_locations"),
    ),
}

SPLIT_DEBUG_INFO_ATTR = {
    "_split_debug_info": attr.label(
        doc = "The //dart:split_debug_info build setting.",
        default = Label("//dart:split_debug_info"),
    ),
}

def split_debug_info(ctx):
    """Whether this configuration's `exe`/`aot-snapshot` binaries split their debugging information.

    Args:
      ctx: Rule context carrying `_split_debug_info`.

    Returns:
      A bool.
    """
    return ctx.attr._split_debug_info[BuildSettingInfo].value

KERNEL_LIST_ATTR = {
    "_kernel_list": attr.label(
        doc = "The //dart:kernel_list build setting.",
        default = Label("//dart:kernel_list"),
    ),
}

MODULAR_KERNEL_ATTR = {
    "_modular_kernel": attr.label(
        doc = "The //dart:modular_kernel build setting.",
        default = Label("//dart:modular_kernel"),
    ),
}

RUNNER_SNAPSHOT_ATTR = {
    "_runner_snapshot": attr.label(
        doc = "The //dart:runner_snapshot build setting.",
        default = Label("//dart:runner_snapshot"),
    ),
}

def runner_snapshot(ctx):
    """Whether this configuration's tests start the runner from a cached snapshot.

    Args:
      ctx: Rule context carrying `_runner_snapshot`.

    Returns:
      A bool.
    """
    return ctx.attr._runner_snapshot[BuildSettingInfo].value

def modular_kernel(ctx):
    """Whether this configuration compiles executables against kernel modules.

    Off (`--@rules_dart//dart:modular_kernel=false`, the build-wide escape
    hatch), the module aspect compiles nothing, and an executable compiles its
    whole program from source.

    Args:
      ctx: Rule or aspect context carrying `_modular_kernel`.

    Returns:
      A bool.
    """
    return ctx.attr._modular_kernel[BuildSettingInfo].value

def kernel_list(ctx):
    """Whether this configuration links a test's program as a kernel list.

    Args:
      ctx: Rule context carrying `_kernel_list`.

    Returns:
      A bool.
    """
    return ctx.attr._kernel_list[BuildSettingInfo].value

def track_creation_locations(ctx):
    """Whether this configuration compiles with `--track-creation-locations`.

    Args:
      ctx: Rule or aspect context carrying `_track_creation_locations`.

    Returns:
      A bool.
    """
    return ctx.attr._track_creation_locations[BuildSettingInfo].value
