"""Which SDKs the root module declares besides `dart.toolchain`'s, and which the build uses."""

load(":toolchain_selection.bzl", "is_published_version")
load(":toolchains_repo.bzl", "PLATFORMS", "cross_tool_basenames")

visibility("//dart/...")

# The tags, each one way of supplying an SDK: its attributes are what that way needs.
CUSTOM_SDK_TAGS = ["release", "custom_sdk", "checkout"]

_NAME_CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

def _unknown_keys(keys, known):
    return sorted([k for k in keys if k not in known])

def _check_platforms(declared, attribute, keys):
    unknown = _unknown_keys(keys, PLATFORMS)
    if unknown:
        return "{} gives `{}` for {}, which are no Dart SDK hosts. The hosts are: {}.".format(
            declared,
            attribute,
            ", ".join(unknown),
            ", ".join(sorted(PLATFORMS.keys())),
        )
    return None

def _check_file(declared, attribute, label, basename, what):
    if label.name.rpartition("/")[2] != basename:
        return "{} gives `{}` as {}, but it must name the `{}` file at the root of {}.".format(
            declared,
            attribute,
            label,
            basename,
            what,
        )
    return None

def _check_cross_tools(declared, attribute, keys):
    unknown = _unknown_keys(keys, cross_tool_basenames())
    if unknown:
        return "{} gives `{}` for {}, which no cross-compilation uses. The files are named as in the Dart archive, such as `gen_snapshot_macos_arm64_linux_x64` and `dartaotruntime_linux_x64`.".format(
            declared,
            attribute,
            ", ".join(unknown),
        )
    return None

def _check_release(tag, declared):
    if not is_published_version(tag.dart_version):
        return ("{} gives `dart_version` {}, which no published Dart SDK has. Name it in full: " +
                "3.14.1, 3.15.0-1.2.beta, 3.15.0-148.0.dev or 3.15.0-edge.<commit>.").format(
            declared,
            tag.dart_version,
        )
    error = _check_platforms(declared, "sdk_sha256", tag.sdk_sha256.keys())
    if error:
        return error
    return _check_cross_tools(declared, "cross_tools_sha256", tag.cross_tools_sha256.keys())

def _check_custom_sdk(tag, declared):
    error = _check_platforms(declared, "sdk", tag.sdk.keys())
    if error:
        return error
    for platform in sorted(tag.sdk.keys()):
        error = _check_file(declared, "sdk", tag.sdk[platform], "version", "a Dart SDK")
        if error:
            return error
    if tag.source:
        error = _check_file(declared, "source", tag.source, "DEPS", "the SDK's source")
        if error:
            return error
    return _check_cross_tools(declared, "cross_tools", tag.cross_tools.keys())

def _check_checkout(tag, declared):
    if tag.checkout:
        error = _check_file(declared, "checkout", tag.checkout, "DEPS", "a dart-lang/sdk checkout")
        if error:
            return error
    return _check_cross_tools(declared, "cross_tools", tag.cross_tools.keys())

_CHECKS = {
    "release": _check_release,
    "custom_sdk": _check_custom_sdk,
    "checkout": _check_checkout,
}

def _error(message):
    return struct(sdks = {}, use = None, error = message)

def sdk_name_error(name, declared):
    """Why `name` cannot name a Dart SDK, if it cannot.

    The toolchains repository's target names rely on it: see `_sdk_target_prefix`.

    Args:
        name: The name.
        declared: The tag declaring it, for the message.

    Returns:
        A message for the user, or None.
    """
    if not name or name[0].isdigit() or name[0] == "_" or [c for c in name.elems() if c not in _NAME_CHARACTERS]:
        return "{}: an SDK's name is a letter followed by letters, digits and underscores.".format(declared)
    return None

def _check_name(name, declared, default_name):
    if name == default_name:
        return ("{} takes the name of the release every module may request a version of. " +
                "Give it another name; to build with it, add dart.use_sdk(name = ...).").format(declared)
    return sdk_name_error(name, declared)

def custom_sdks(modules, release_names, default_name):
    """The SDKs the root module declares and chooses, or why the tags cannot stand.

    Args:
        modules: The modules, as `module_ctx.modules` gives them: each with
            `name`, `is_root` and a `tags` list for `use_sdk` and for each of
            `CUSTOM_SDK_TAGS`.
        release_names: The names a `dart.toolchain` declares, in any module.
        default_name: The name of the release every module may request.

    Returns:
        A struct: `sdks`, each name's `struct(kind, tag)`, `kind` being the
        tag's name in `CUSTOM_SDK_TAGS`; `use`, the name `dart.use_sdk` gives,
        or None; and `error`, None or why the tags cannot stand.
    """
    sdks = {}
    for mod in modules:
        for kind in CUSTOM_SDK_TAGS:
            for tag in getattr(mod.tags, kind):
                declared = 'dart.{}(name = "{}")'.format(kind, tag.name)
                if not mod.is_root:
                    return _error((
                        "{} in module {} declares a Dart SDK. Only the root module may: " +
                        "a library must not decide the SDK of the programs that use it."
                    ).format(declared, mod.name))
                error = _check_name(tag.name, declared, default_name)
                if error:
                    return _error(error)
                if tag.name in sdks:
                    return _error('"{}" is declared twice: by dart.{}() and by dart.{}().'.format(
                        tag.name,
                        sdks[tag.name].kind,
                        kind,
                    ))
                if tag.name in release_names:
                    return _error((
                        '"{0}" is declared by both {1} and dart.toolchain(name = "{0}"). ' +
                        "An SDK is one or the other: give one of them another name."
                    ).format(tag.name, declared))
                error = _CHECKS[kind](tag, declared)
                if error:
                    return _error(error)
                sdks[tag.name] = struct(kind = kind, tag = tag)

    use = None
    for mod in modules:
        for tag in mod.tags.use_sdk:
            if not mod.is_root:
                return _error((
                    'dart.use_sdk(name = "{}") in module {} chooses the Dart SDK. Only the root ' +
                    "module may: a library must not decide the SDK of the programs that use it."
                ).format(tag.name, mod.name))
            if use != None:
                return _error('The root module chooses two Dart SDKs: dart.use_sdk(name = "{}") and dart.use_sdk(name = "{}"). Keep one.'.format(use, tag.name))
            use = tag.name
    declared_names = sorted(list(release_names) + sdks.keys())
    if use != None and use not in declared_names:
        return _error('dart.use_sdk(name = "{}") names no declared Dart SDK. The declared SDKs are: {}.'.format(
            use,
            ", ".join(declared_names),
        ))
    return struct(sdks = sdks, use = use, error = None)
