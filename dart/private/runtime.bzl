"""The runtime a target is built for, and the transitions that set it.

The runtime is a constraint of the target platform,
`@rules_dart//dart/constraints:runtime`: `vm` (the default), `js`
(dart2js, and DDC) or `wasm` (dart2wasm). `dart_js_binary` and
`dart_wasm_binary` build their `deps` for a platform that carries `js` or
`wasm` (their `platform` attribute), so a `select()` on
`@rules_dart//dart/constraints:js` or `:wasm` in a library's `deps` picks that
compiler's variant.

Every target under a web binary is configured for the web platform, whether or
not its outputs depend on it. Targets whose outputs cannot (codegen, pub
packages, code assets, native modules) go back, on their incoming edge, to the
platforms the build had before the web transition, which rejoins that
configuration exactly, so they and everything under them are built once,
shared by every web binary and by any VM build. That needs the earlier
platforms, which a transition cannot otherwise see once `--platforms` is
replaced: the web transitions record them in a private setting, and the reset
restores them and clears it. This is rules_go's mechanism for its own settings
(`go_transition` records `original_*`, `non_go_transition` restores them).

`--@rules_dart//dart:track_creation_locations` forks the same targets: a Flutter
test turns it on for everything beneath it, and an app beside it leaves it off.
Only a rule nothing of which is compiled Dart (codegen, code assets, native
modules) can turn it off: a library's kernel modules are compiled in its own
configuration, and one compiled without the transform cannot be linked with
one compiled with it. So pub packages keep it, and `non_dart_transition` resets
both settings where `runtime_reset` resets the platform alone. An
executable's environment declarations (`executable_defines_config`) fork them
the same way, and `non_dart_transition` clears those too.
"""

visibility("//dart/...")

_TRACK_CREATION_LOCATIONS = str(Label("//dart:track_creation_locations"))
_MODULE_DEFINES = str(Label("//dart/private:module_defines"))

PLATFORMS = "//command_line_option:platforms"

# The incoming `--platforms`, JSON-encoded, while under a web transition; ""
# otherwise. JSON tells "not under one" from any list, empty included.
PLATFORMS_BEFORE_WEB = str(Label("//dart/private:platforms_before_web"))

# What a transition to a web platform reads and writes.
WEB_PLATFORM_SETTINGS = [PLATFORMS, PLATFORMS_BEFORE_WEB]

def web_platform_settings(settings, platform):
    """The settings that build for `platform`, a web platform.

    For a rule set's own transition, when its branches are computed from more
    than a platform attribute: it takes `WEB_PLATFORM_SETTINGS` among its
    `inputs` and `outputs` and returns this for each branch.

    Args:
        settings: The transition's incoming settings.
        platform: The web platform's label.

    Returns:
        A dict of the `WEB_PLATFORM_SETTINGS`.
    """
    before = settings[PLATFORMS_BEFORE_WEB]
    if not before:
        before = json.encode([str(p) for p in settings[PLATFORMS]])
    return {PLATFORMS: [str(platform)], PLATFORMS_BEFORE_WEB: before}

def web_platform_config_settings(platform, platforms = [Label("@bazel_tools//tools:host_platform")]):
    """`config_settings` for an analysis test of a target built for `platform`, a web platform.

    The fixed-dict form of `web_platform_settings`, for
    `analysistest.make(config_settings = ...)`: the target under test is
    configured as a web transition from a build for `platforms` configures it,
    so the resets beneath it go back to `platforms`. (Bazel keeps everything
    under a test's `config_settings` in configurations of its own, so they
    rejoin the test's plain configuration, not the build's outside it.) A dict
    cannot read the platforms the test is built for, so `platforms` states
    them: Bazel's default, the host, unless the tests run under another
    `--platforms`.

    Args:
        platform: The web platform's `Label`.
        platforms: The `Label`s of the platforms the build had before the web
            transition.

    Returns:
        A dict of the `WEB_PLATFORM_SETTINGS`; merge any other settings into it.
    """
    return web_platform_settings({PLATFORMS: platforms, PLATFORMS_BEFORE_WEB: ""}, platform)

def _web_platform_impl(settings, attr):
    return web_platform_settings(settings, attr.platform)

# 1:1, to the platform in the rule's `platform` attribute.
web_platform_transition = transition(
    implementation = _web_platform_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS,
)

def _web_platforms_impl(settings, attr):
    if not attr.web_platforms:
        return {"": {PLATFORMS: settings[PLATFORMS], PLATFORMS_BEFORE_WEB: settings[PLATFORMS_BEFORE_WEB]}}
    return {str(p): web_platform_settings(settings, p) for p in attr.web_platforms}

# 1:N, one branch per platform in the rule's `web_platforms` attribute, keyed
# by its label; with none listed, the one incoming configuration.
web_platforms_transition = transition(
    implementation = _web_platforms_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS,
)

def _restore(settings):
    before = settings[PLATFORMS_BEFORE_WEB]
    if not before:
        return {PLATFORMS: settings[PLATFORMS], PLATFORMS_BEFORE_WEB: ""}
    return {PLATFORMS: json.decode(before), PLATFORMS_BEFORE_WEB: ""}

def _reset_impl(settings, _attr):
    return _restore(settings)

runtime_reset = transition(
    implementation = _reset_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS,
)

def _non_dart_transition_impl(settings, _attr):
    return _restore(settings) | {_TRACK_CREATION_LOCATIONS: False, _MODULE_DEFINES: []}

# `runtime_reset`, `track_creation_locations` off and no executable's
# environment: for a rule nothing of which is compiled Dart.
non_dart_transition = transition(
    implementation = _non_dart_transition_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS + [_TRACK_CREATION_LOCATIONS, _MODULE_DEFINES],
)

def _reset_when_independent_impl(settings, attr):
    if attr.runtime_independent:
        return _restore(settings)
    return {PLATFORMS: settings[PLATFORMS], PLATFORMS_BEFORE_WEB: settings[PLATFORMS_BEFORE_WEB]}

runtime_reset_when_independent = transition(
    implementation = _reset_when_independent_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS,
)

RUNTIME_INDEPENDENT_ATTR = {
    "runtime_independent": attr.bool(
        doc = """Whether this target and everything it depends on are the same under \
every web compiler. Set by `pub.from_lock()` and `pub.package()` on every pub package, which \
cannot `select()` on `@rules_dart//dart/constraints:runtime`. When set, the target is built \
once, for the platform the build had before any web binary's transition, however many web \
binaries reach it, instead of once per web platform: a `select()` on the runtime anywhere \
beneath it sees `vm`. Leave it unset on a library that is, or depends on, per-compiler code.""",
    ),
}

RuntimeInfo = provider(
    doc = "The runtime the target platform of a configuration carries.",
    fields = {"value": "`vm`, `js` or `wasm`."},
)

def _target_runtime_impl(ctx):
    for value in ["js", "wasm"]:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, "_" + value)[platform_common.ConstraintValueInfo]):
            return [RuntimeInfo(value = value)]
    return [RuntimeInfo(value = "vm")]

# Reached through a binary's web transition, it says which compiler the
# platform it was given carries, so the binary can refuse one that carries the
# wrong one or none.
target_runtime = rule(
    implementation = _target_runtime_impl,
    attrs = {
        "_js": attr.label(default = "//dart/constraints:js"),
        "_wasm": attr.label(default = "//dart/constraints:wasm"),
    },
)

_EXTRA_DART_DEFINES = str(Label("//dart:extra_dart_defines"))

def _dart_tool_reset_impl(settings, attr):
    return _non_dart_transition_impl(settings, attr) | {_EXTRA_DART_DEFINES: []}

# `non_dart_transition` and no command-line declarations: for rules_dart's own
# tools, which are compiled without `kernel_tool` and so cannot track creation
# locations or take a declaration `gen_kernel` would split, and which are the
# same program whatever the build that reaches them compiles.
dart_tool_reset = transition(
    implementation = _dart_tool_reset_impl,
    inputs = WEB_PLATFORM_SETTINGS,
    outputs = WEB_PLATFORM_SETTINGS + [_TRACK_CREATION_LOCATIONS, _MODULE_DEFINES, _EXTRA_DART_DEFINES],
)
