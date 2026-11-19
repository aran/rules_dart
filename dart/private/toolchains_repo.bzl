"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
Former will be always fetched,
and the latter will only be fetched when user actually needs to build <LANG> code.
"
The "complex computation" in our case is simply downloading large artifacts.
This guidance tells us how to avoid that: we put the toolchain targets in this repository, and
what they name is fetched only when a build resolves that toolchain. A release's `dart_toolchain`
targets are here too, naming the files in its repositories, which then hold only the release.
"""

load(":platforms.bzl", _PLATFORMS = "PLATFORMS", _host_platform = "host_platform", _unsupported_host_message = "unsupported_host_message")

visibility("//dart/...")

PLATFORMS = _PLATFORMS

host_platform = _host_platform
unsupported_host_message = _unsupported_host_message

# Cross-compilation destinations with no SDK download and no host support.
# `dart compile exe/aot-snapshot` reuses the HOST SDK's `dart` binary with
# --target-os/--target-arch, so no `dartsdk-<key>-release.zip` is fetched and no
# `versions.bzl` checksum is needed. Keys are still real SDK slugs, so promoting
# one to a full `PLATFORMS` entry later is a move plus its checksums.
#
# Neither is a host: Bazel publishes no riscv64 or armv7 release, so neither CPU
# can ever be an exec platform.
TARGET_ONLY_PLATFORMS = {
    "linux-riscv64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:riscv64",
        ],
        dart_os = "linux",
        dart_arch = "riscv64",
    ),
    # Dart's `linux-arm` is armv7 hardfloat. NOTE: `@platforms//cpu:arm` is an
    # ALIAS for `aarch32` — a different constraint value — and constraint
    # matching has no subtyping, so a user platform declaring `:arm` will NOT
    # resolve this toolchain. It must declare `:armv7`.
    "linux-arm": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:armv7",
        ],
        dart_os = "linux",
        dart_arch = "arm",
    ),
}

# Every platform usable as a cross-compilation TARGET: hosts plus target-only.
TARGET_PLATFORMS = dict(PLATFORMS)

TARGET_PLATFORMS.update(TARGET_ONLY_PLATFORMS)

# Known-working cross-compilation pairs: exec platform -> list of target platforms.
# Dart's AOT compiler can cross-compile exe and aot-snapshot to these targets
# using --target-os and --target-arch flags. Keys must be `PLATFORMS` (an exec
# platform needs an SDK); values must be `TARGET_PLATFORMS`.
CROSS_TARGETS = {
    "macos-arm64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
    "macos-x64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
    "linux-x64": ["linux-arm64", "linux-riscv64", "linux-arm"],
    "linux-arm64": ["linux-x64", "linux-riscv64", "linux-arm"],
    "windows-x64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
    "windows-arm64": ["linux-x64", "linux-arm64", "linux-riscv64", "linux-arm"],
}

# Where dartdev's `SdkCache` looks for a cross target's files, under `$HOME`
# (`%APPDATA%` on Windows): `.dart/dartdev/sdk_cache/<version>/<basename>`.
SDK_CACHE_DIR = ".dart/dartdev/sdk_cache"

def cross_tool_files(exec_platform, target_platform):
    """The files `dart compile` fetches to cross-compile for one pair.

    Args:
        exec_platform: A `PLATFORMS` key, the host the compiler runs on.
        target_platform: A `TARGET_PLATFORMS` key, the machine it compiles for.

    Returns:
        `struct(gen_snapshot, dartaotruntime)`, each the file's basename in the
        Dart archive and in dartdev's `sdk_cache`, and the `CROSS_TOOL_VERSIONS`
        key of its checksum.
    """
    host = PLATFORMS[exec_platform]
    target = TARGET_PLATFORMS[target_platform]
    target_slug = target.dart_os + "_" + target.dart_arch
    gen_snapshot = "gen_snapshot_%s_%s_%s" % (host.dart_os, host.dart_arch, target_slug)
    if host.dart_os == "windows":
        gen_snapshot += ".exe"
    return struct(
        gen_snapshot = gen_snapshot,
        dartaotruntime = "dartaotruntime_" + target_slug,
    )

def build_root_cross_tools(exec_platform, target_platform):
    """What `dart compile` looks for beside an SDK it takes for a local build.

    Args:
        exec_platform: A `PLATFORMS` key, the host the compiler runs on.
        target_platform: A `TARGET_PLATFORMS` key, the machine it compiles for.

    Returns:
        `struct(gen_snapshot, dartaotruntime)`, each the file's name in a
        dart-lang/sdk build directory.
    """
    target = TARGET_PLATFORMS[target_platform]
    slug = target.dart_os + "_" + target.dart_arch
    gen_snapshot = "gen_snapshot_product_" + slug
    if PLATFORMS[exec_platform].dart_os == "windows":
        gen_snapshot += ".exe"
    return struct(gen_snapshot = gen_snapshot, dartaotruntime = "dartaotruntime_product_" + slug)

# The name of the SDK every module may request a version of.
DEFAULT_SDK_NAME = "dart"

_SDK_FLAG = "@rules_dart//dart:sdk"

def cross_tool_basenames():
    """The files cross-compilation pairs fetch.

    Returns:
        Each file's basename in the Dart archive, sorted.
    """
    names = {}
    for exec_platform, targets in CROSS_TARGETS.items():
        for target_platform in targets:
            files = cross_tool_files(exec_platform, target_platform)
            names[files.gen_snapshot] = True
            names[files.dartaotruntime] = True
    return sorted(names.keys())

def dart_bin(platform):
    """The path of `dart` in a platform's SDK.

    Args:
        platform: A `PLATFORMS` key.

    Returns:
        The path, relative to the SDK's root.
    """
    return "bin/dart.exe" if platform.startswith("windows") else "bin/dart"

# What a BUILD file holding `sdk_error_target`s loads.
SDK_ERROR_LOAD = 'load("@rules_dart//dart/private:sdk_error.bzl", "dart_sdk_error", "dart_sdk_tool_error")\n'

def sdk_error_target(name, message):
    """A target failing the build with `message` when something uses it, as BUILD text.

    Whatever an SDK lacks is such a target, and no repository fails for it:
    `bazel fetch --all` and `bazel vendor` fetch every repository, the parts of
    SDKs this machine cannot use among them.

    Args:
        name: The target's name.
        message: What is wrong, and the fix.

    Returns:
        The target, for a BUILD file with `SDK_ERROR_LOAD`.
    """
    return """
dart_sdk_error(
    name = "{name}",
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = name, message = json.encode(message))

def sdk_tool_error_target(name, message):
    """A tool that fails the build with `message` when it is built, as BUILD text.

    A toolchain names its tool whether or not anything runs it, so a tool an SDK
    lacks must let the toolchain be analyzed: see `dart_sdk_tool_error`.

    Args:
        name: The target's name.
        message: What is wrong, and the fix.

    Returns:
        The target, for a BUILD file with `SDK_ERROR_LOAD`.
    """
    return """
dart_sdk_tool_error(
    name = "{name}",
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = name, message = json.encode(message))

def sdk_tool_toolchains(version, tools, prefix = ""):
    """The outline and analyzer toolchains of one SDK, as BUILD text.

    Each tool is that of the SDK's own source. It is unset when its flag is
    off, so that source is not fetched.

    Args:
        version: The SDK's version.
        tools: `kernel` and `analyzer`, each the part holding that tool (see
            `toolchains_build_content`).
        prefix: Prefixed to the targets' names.

    Returns:
        The targets `<prefix>outline` and `<prefix>analyzer`, for a BUILD file
        with `SDK_ERROR_LOAD`.
    """
    content = ""
    labels = {}
    for tool, target in [("kernel", "outline_tool"), ("analyzer", "summary_analyzer")]:
        part = tools[tool]
        if "error" in part:
            name = "%s%s_unavailable" % (prefix, tool)
            content += sdk_tool_error_target(name, part["error"])
            labels[tool] = ":" + name
        else:
            labels[tool] = "@%s//:%s" % (part["repo"], target)
    return content + """
dart_outline_toolchain(
    name = "{prefix}outline",
    tool = select({{
        "@rules_dart//dart:is_outline_kernel": "{kernel}",
        "//conditions:default": None,
    }}),
    version = "{version}",
    visibility = ["//visibility:public"],
)

dart_analyzer_toolchain(
    name = "{prefix}analyzer",
    tool = select({{
        "@rules_dart//dart:is_analysis_summaries": "{analyzer}",
        "//conditions:default": None,
    }}),
    version = "{version}",
    visibility = ["//visibility:public"],
)
""".format(prefix = prefix, kernel = labels["kernel"], analyzer = labels["analyzer"], version = version)

def _toolchain(name, toolchain_type, toolchain, settings = None, exec_compatible_with = None, target_compatible_with = None):
    lines = ["toolchain(", '    name = "%s",' % name]
    if exec_compatible_with:
        lines.append("    exec_compatible_with = %s," % json.encode(exec_compatible_with))
    if target_compatible_with:
        lines.append("    target_compatible_with = %s," % json.encode(target_compatible_with))
    if settings:
        lines.append('    target_settings = [":%s"],' % settings)
    lines += [
        '    toolchain = "%s",' % toolchain,
        '    toolchain_type = "@rules_dart//dart:%s",' % toolchain_type,
        ")",
    ]
    return "\n" + "\n".join(lines) + "\n"

def _sdk_target_prefix(sdk):
    """What starts the name of every target of one SDK in the toolchains repository.

    An SDK's name has no `-`, so what precedes the first `-` is the SDK, and the
    repository's own targets, whose names have none, are no SDK's: no name an
    SDK is given can make two targets collide.
    """
    return sdk + "-"

def cross_pair(platform, target):
    """The key of a cross-compilation pair in an SDK's `cross` parts.

    Args:
        platform: The `PLATFORMS` key of the host.
        target: The `TARGET_PLATFORMS` key of the target.

    Returns:
        The key.
    """
    return "%s/%s" % (platform, target)

def _release_compiler(name, repo, version, platform, target, cross):
    """The `dart_toolchain` of a release, over the repositories holding its files.

    It is here rather than in the SDK's repository so that what Bazel stores for
    a release depends on the release alone: see `dart_sdk_repo_attrs`. Being
    outside those repositories it gets no package metadata from them, so it names
    theirs: an SBOM tool reaches the SDK through the toolchain target.
    """
    meta = PLATFORMS[platform]
    metadata = ["@%s//:package_metadata" % repo]
    lines = [
        "dart_toolchain(",
        '    name = "%s",' % name,
        '    dart = "@%s//:%s",' % (repo, dart_bin(platform)),
        '    sdk = "@%s//:sdk",' % repo,
        '    version = "%s",' % version,
        '    exec_os = "%s",' % meta.dart_os,
        '    exec_arch = "%s",' % meta.dart_arch,
    ]
    if target:
        target_meta = TARGET_PLATFORMS[target]
        lines += [
            '    target_os = "%s",' % target_meta.dart_os,
            '    target_arch = "%s",' % target_meta.dart_arch,
        ]
        if cross.get("repo"):
            lines.append('    sdk_cache = "@%s//:sdk_cache",' % cross["repo"])
            metadata.append("@%s//:package_metadata" % cross["repo"])
        if cross.get("missing"):
            lines.append("    missing_cross_tools = %s," % json.encode(cross["missing"]))
    lines.append("    package_metadata = %s," % json.encode(metadata))
    return "\n" + "\n".join(lines + [")"]) + "\n"

def _sdk_toolchains(sdk, parts, unavailable):
    """The toolchains of one SDK, each applying when the build uses that SDK."""
    prefix = _sdk_target_prefix(sdk)
    settings = prefix + "uses"
    version = parts["version"]

    # The targets `compiler` needs here, by name.
    targets = {}

    def compiler(platform, target = None):
        if unavailable:
            return ":%sunavailable" % prefix
        host = parts["hosts"][platform]
        cross = parts["cross"][cross_pair(platform, target)] if target else {}
        name = prefix + platform + ("_cross_" + target if target else "") + "_sdk"
        error = host.get("error") or cross.get("error")
        if error:
            targets[name] = sdk_error_target(name, error)
        elif version:
            targets[name] = _release_compiler(name, host["repo"], version, platform, target, cross)
        elif target:
            # Only the SDK's own files say its version, so a repository reading
            # them holds the toolchain: one for the host, one for each pair.
            return "@%s//:dart_toolchain_cross_%s" % (cross["repo"], target)
        else:
            return "@%s//:dart_toolchain" % host["repo"]
        return ":" + name

    content = ""
    if unavailable:
        content += sdk_error_target(prefix + "unavailable", unavailable)

    # Native toolchains: exec and target constraints match the same platform.
    for platform, meta in PLATFORMS.items():
        content += _toolchain(
            prefix + platform + "_toolchain",
            "toolchain_type",
            compiler(platform),
            settings,
            exec_compatible_with = meta.compatible_with,
            target_compatible_with = meta.compatible_with,
        )

    # Exec-tools toolchains: the codegen rules run a generator on the exec/host
    # machine and emit platform-agnostic Dart source, so SDK selection must not
    # depend on the build's target platform. One per host platform with
    # exec_compatible_with pinned and target_compatible_with omitted, so each
    # matches any target platform (iOS, Android, …). Reuses the native
    # dart_toolchain (the host SDK).
    for platform, meta in PLATFORMS.items():
        content += _toolchain(
            prefix + platform + "_exec_tools_toolchain",
            "exec_tools_toolchain_type",
            compiler(platform),
            settings,
            exec_compatible_with = meta.compatible_with,
        )

    # Cross-compilation toolchains: exec constraints = host, target constraints = cross target.
    for exec_platform, cross_targets in CROSS_TARGETS.items():
        for target_platform in cross_targets:
            content += _toolchain(
                "{}{}_cross_{}_toolchain".format(prefix, exec_platform, target_platform),
                "toolchain_type",
                compiler(exec_platform, target_platform),
                settings,
                exec_compatible_with = PLATFORMS[exec_platform].compatible_with,
                target_compatible_with = TARGET_PLATFORMS[target_platform].compatible_with,
            )

    # The outline stripper and the summary analyzer of the same SDK. An SDK
    # whose version only its own files say has them in a repository that reads it.
    if version:
        content += sdk_tool_toolchains(version, parts["tools"], prefix)
        tools = ":" + prefix
    else:
        tools = "@%s_tools//:" % sdk
    content += _toolchain(prefix + "outline_toolchain", "outline_toolchain_type", tools + "outline", settings)
    content += _toolchain(prefix + "analyzer_toolchain", "analyzer_toolchain_type", tools + "analyzer", settings)
    return "".join(targets.values()) + content

def toolchains_build_content(sdks, default_sdk, unavailable):
    """The `BUILD.bazel` holding the toolchains of every declared SDK.

    Args:
        sdks: What each SDK is made of, by name: a dict with `version`, empty
            when only the SDK's files say; `hosts`, by `PLATFORMS` key; `cross`,
            by `cross_pair`; and `tools`, with `kernel` and `analyzer`. Each of
            those is a part: `repo`, the repository holding it, or `error`, why
            there is none, which stops only a build using it. A release's
            `cross` part has `missing` instead of `error`, the message for each
            tool without a checksum (`gen_snapshot`, `dartaotruntime`), and no
            `repo` when that is both.
        default_sdk: The SDK a build without `--@rules_dart//dart:sdk` uses.
        unavailable: Why an SDK cannot be used, by name, for those that cannot.

    Returns:
        The file.
    """
    names = sorted(sdks.keys())
    content = """# Generated by toolchains_repo.bzl
#
# The toolchains of every Dart SDK the root module declares. Each applies when
# the build uses its SDK: the one `--@rules_dart//dart:sdk` names, or without
# the flag the one the root module chooses, "{default_sdk}".
# rules_dart's own MODULE.bazel registers them.

load("@rules_dart//dart:toolchain.bzl", "dart_analyzer_toolchain", "dart_outline_toolchain", "dart_toolchain")
{error_load}
config_setting(
    name = "flag_unset",
    flag_values = {{"{flag}": ""}},
)
""".format(default_sdk = default_sdk, flag = _SDK_FLAG, error_load = SDK_ERROR_LOAD)

    for sdk in names:
        content += """
config_setting(
    name = "{prefix}chosen",
    flag_values = {{"{flag}": "{sdk}"}},
)

alias(
    name = "{prefix}uses",
    actual = select({{
        ":{prefix}chosen": "@rules_dart//dart/private:sdk_always",
{default}        "//conditions:default": "@rules_dart//dart/private:sdk_never",
    }}),
)
""".format(
            prefix = _sdk_target_prefix(sdk),
            sdk = sdk,
            flag = _SDK_FLAG,
            default = '        ":flag_unset": "@rules_dart//dart/private:sdk_always",\n' if sdk == default_sdk else "",
        )

    # A name no tag declares: an error listing the names, not "no toolchain".
    content += """
alias(
    name = "uses_undeclared_sdk",
    actual = select({{
        ":flag_unset": "@rules_dart//dart/private:sdk_never",
{declared}        "//conditions:default": "@rules_dart//dart/private:sdk_always",
    }}),
)

{error}""".format(
        declared = "".join([
            '        ":{}chosen": "@rules_dart//dart/private:sdk_never",\n'.format(_sdk_target_prefix(sdk))
            for sdk in names
        ]),
        error = sdk_error_target(
            "undeclared_sdk",
            "--@rules_dart//dart:sdk names no Dart SDK the root module declares. The declared SDKs are: {}.".format(", ".join(names)),
        ).lstrip("\n"),
    )
    content += _toolchain("undeclared_sdk_toolchain", "toolchain_type", ":undeclared_sdk", "uses_undeclared_sdk")
    content += _toolchain("undeclared_sdk_exec_tools_toolchain", "exec_tools_toolchain_type", ":undeclared_sdk", "uses_undeclared_sdk")

    for sdk in names:
        content += _sdk_toolchains(sdk, sdks[sdk], unavailable.get(sdk))
    return content

def toolchains_repo_impl(repository_ctx):
    """Implementation of `toolchains_repo`, exposed so a test can run it.

    Args:
        repository_ctx: The `repository_ctx`.

    Returns:
        Metadata marking the repository reproducible.
    """
    repository_ctx.file("BUILD.bazel", toolchains_build_content(
        {name: json.decode(parts) for name, parts in repository_ctx.attr.sdks.items()},
        repository_ctx.attr.default_sdk,
        repository_ctx.attr.unavailable,
    ))
    return repository_ctx.repo_metadata(reproducible = True)

def host_toolchains_build_content(message):
    """The BUILD file of `dart_host_toolchains`.

    Args:
        message: Why this host has no Dart SDK, or None if it has one.

    Returns:
        The file: nothing to register on a host with an SDK, and on one without,
        toolchains matching anything that fail the build with `message`, so
        that it does not end in Bazel's report of no matching toolchain.
    """
    content = "# Generated by dart/private/toolchains_repo.bzl\n"
    if message:
        content += SDK_ERROR_LOAD + sdk_error_target("unsupported_host", message)
        content += _toolchain("unsupported_host_toolchain", "toolchain_type", ":unsupported_host")
        content += _toolchain("unsupported_host_exec_tools_toolchain", "exec_tools_toolchain_type", ":unsupported_host")
    return content

def _dart_host_toolchains_impl(repository_ctx):
    host = host_platform(repository_ctx.os)
    repository_ctx.file("BUILD.bazel", host_toolchains_build_content(
        None if host else unsupported_host_message(repository_ctx.os),
    ))

dart_host_toolchains = repository_rule(
    _dart_host_toolchains_impl,
    doc = "On a host with no Dart SDK, toolchains failing every build that needs one, saying so. Apart from `toolchains_repo`, whose contents depend on no host.",
)

toolchains_repo = repository_rule(
    toolchains_repo_impl,
    doc = """Creates the repository with the toolchains of every declared Dart SDK, for
     all known platforms, which rules_dart's own `MODULE.bazel` registers.""",
    attrs = {
        "default_sdk": attr.string(doc = "The SDK a build without `--@rules_dart//dart:sdk` uses.", mandatory = True),
        "sdks": attr.string_dict(doc = "What each SDK is made of, by name, as JSON: see `toolchains_build_content`.", mandatory = True),
        "unavailable": attr.string_dict(doc = "Why an SDK cannot be used, by name, for those that cannot."),
    },
)
