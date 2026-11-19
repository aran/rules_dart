"""Extensions for bzlmod.

Installs a Dart toolchain.
Every module can define a toolchain version under the default name, "dart", and
every such request is a minimum: no module gets an SDK older than it requested.
Which version is installed depends on the root module:

* If the root module requests a version, that exact version is used. A
  dependency requesting a newer one fails a build using this SDK, naming the
  dependency and its version. The root raises its pin to at least that version,
  sets `allow_upgrade_by_dependencies = True` on its `dart.toolchain`, which lets
  the highest of all requests, the root's included, win, or builds with another
  SDK.
* If the root module requests none, the newest version rules_dart serves is
  used, and a dependency's older request is raised to it. A dependency requesting
  a newer one fails a build using this SDK. rules_dart requests no version of its
  own as a dependency: it serves every version in `versions.bzl`.
* The root module may request one version per name; two requests for a name fail.

The root module can declare more SDKs, each under a name of its own, and each
way of supplying one is its own tag: `dart.toolchain` (a release rules_dart
pins), `dart.release` (another published release, with its checksums),
`dart.custom_sdk` (an SDK inside other repositories) and `dart.checkout` (one
built in a dart-lang/sdk checkout).

rules_dart builds with Dart 3.13.0 and newer: a build using an older SDK fails,
saying so.

A build uses one SDK. `dart.use_sdk` in the root module says which, and without
it the build uses `dart`. `--@rules_dart//dart:sdk=<name>` overrides that choice
for one build. A dependency's request is checked against whichever SDK is used,
when that SDK is used, so an SDK that cannot serve the build stops only the
builds using it.
"""

load("//dart/private:custom_sdks.bzl", "custom_sdks", "sdk_name_error")
load("//dart/private:local_sdk.bzl", "dart_checkout_cross_sdk", "dart_checkout_sdk", "dart_checkout_sdk_tools", "dart_local_cross_sdk", "dart_local_sdk", "dart_local_sdk_tools")
load("//dart/private:toolchain_selection.bzl", "named_toolchain_requests", "newest_version", "sdk_too_old_error", "select_toolchain_version", "servable_release")
load("//dart/private:toolchains_repo.bzl", "CROSS_TARGETS", "DEFAULT_SDK_NAME", "PLATFORMS", "cross_pair", "dart_bin", "dart_host_toolchains", "toolchains_repo")
load("//dart/private:versions.bzl", "TOOL_VERSIONS")
load("//dart/pub/private/pubspec_reader:reader.bzl", "pubspec_reader_repositories")
load(":repositories.bzl", "dart_checkout_source_tool", "dart_local_cross_sdk_build_file", "dart_local_sdk_build_file", "dart_release_repositories", "dart_sdk_source_tool")

_DEFAULT_NAME = DEFAULT_SDK_NAME

dart_toolchain = tag_class(
    doc = "A Dart SDK release rules_dart pins, and its toolchains under `name`.",
    attrs = {
        "name": attr.string(doc = """\
The name of this SDK. `dart` is the default; any other name is another SDK,
which `dart.use_sdk` or `--@rules_dart//dart:sdk` chooses. A name other than the
default is only permitted in the root module.
""", default = _DEFAULT_NAME),
        "dart_version": attr.string(doc = """\
Explicit version of the Dart SDK. In the root module it is used exactly, and a
dependency requesting a newer one fails a build using this SDK unless
`allow_upgrade_by_dependencies` is set. In any other module it is the oldest
SDK the module accepts.
""", mandatory = True),
        "allow_upgrade_by_dependencies": attr.bool(doc = """\
Lets dependencies raise the SDK version: when a module requests a newer Dart SDK
than the root module's `dart_version`, the highest request is used instead of
failing builds using this SDK. A dependency's request is of `dart`, and counts
under every name. Only the root module may set it.
""", default = False),
    },
)

_SDK_NAME_DOC = """\
The name of the SDK this declares: what `dart.use_sdk` and
`--@rules_dart//dart:sdk` choose it by. Not `dart`, the release every module may
request a version of.
"""

_CROSS_TOOLS_DOC = """\
The files cross-compiling needs, by their names in the Dart archive, as in
`dart.release`'s `cross_tools_sha256`: `gen_snapshot_<host>_<target>`, which runs
on the host, and `dartaotruntime_<target>`, for an `exe`. Each label names the
file. A cross compile needing a file nothing gives fails, naming it.
"""

dart_release = tag_class(
    doc = """\
A published Dart release rules_dart does not pin, with its checksums. Root module only.

A checksum left out stops only a build that runs or compiles with that file, and
the failure names it: `dartaotruntime_<target>` only for an `exe`, or an
`aot-snapshot` on SDKs before 3.15.0-81.0.dev; `source_sha256` only for a build
that runs the outline stripper or the summary analyzer. The Dart archive publishes the checksum of each SDK archive and
`gen_snapshot` beside it, as `<file>.sha256sum`.
""",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "dart_version": attr.string(doc = """\
The release: `3.15.0`, or a beta or dev channel's `3.15.0-1.2.beta`.
""", mandatory = True),
        "sdk_sha256": attr.string_dict(doc = """\
The SHA-256 of each host's SDK archive, by host: `macos-arm64`, `macos-x64`,
`linux-x64`, `linux-arm64`, `windows-x64`.
"""),
        "source_sha256": attr.string(doc = """\
The SHA-256 of the GitHub source archive of the release's tag, from which the
outline stripper and the summary analyzer are built.
"""),
        "cross_tools_sha256": attr.string_dict(doc = """\
The SHA-256 of each file cross-compiling needs, by its name in the Dart archive:
`gen_snapshot_<host>_<target>` and `dartaotruntime_<target>`.
"""),
    },
)

dart_custom_sdk = tag_class(
    doc = """\
A Dart SDK that other repositories hold, such as a fork's build. Root module only.

The SDK's version is what its `version` file says.
""",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "sdk": attr.string_keyed_label_dict(doc = """\
The `version` file at the root of the SDK for each host (`macos-arm64`,
`macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64`). Beside it the directory
must be laid out as the SDK archive is, with `bin/` and `lib/`. A build on a
host not listed fails, naming it.
""", mandatory = True),
        "source": attr.label(doc = """\
The `DEPS` file at the root of this SDK's source (dart-lang/sdk or a fork of
it), from whose `pkg/` the outline stripper and the summary analyzer are built.
Without it, a build needing either fails, naming this attribute and the flag
that turns the tool off.
"""),
        "cross_tools": attr.string_keyed_label_dict(doc = _CROSS_TOOLS_DOC),
    },
)

dart_checkout = tag_class(
    doc = """\
A Dart SDK built in a dart-lang/sdk checkout with `tools/build.py create_sdk`.
Root module only.

The checkout's path is specific to a machine, so it is not an attribute: it is
the environment variable `path_env` names, set in `.bazelrc.user`:

    common --repo_env=DART_CHECKOUT=/path/to/dart-sdk/sdk

The SDK is the one built for this machine in `out/` or `xcodebuild/`, and the
outline stripper and summary analyzer are built from the checkout's `pkg/`.
""",
    attrs = {
        "name": attr.string(doc = _SDK_NAME_DOC, mandatory = True),
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "DART_CHECKOUT",
        ),
        "build_env": attr.string(
            doc = "The environment variable naming the build directory (`ReleaseARM64`), when the checkout holds several SDKs for this machine.",
            default = "DART_CHECKOUT_BUILD",
        ),
        "checkout": attr.label(doc = """\
The `DEPS` file at the root of a checkout that another repository lays out, in
place of the environment variable: for a checkout Bazel itself produces.
"""),
        "cross_tools": attr.string_keyed_label_dict(doc = _CROSS_TOOLS_DOC + """\
A file not named here is taken from the build directory when the checkout built
it there: `create_sdk` builds `gen_snapshot_product_linux_<arch>`. The target's
`dartaotruntime` comes from a build for that target, so it is usually named here.
"""),
    },
)

dart_use_sdk = tag_class(
    doc = """\
Chooses the Dart SDK the build uses, from those declared. Root module only, once.

Without it the build uses `dart`. `--@rules_dart//dart:sdk=<name>`, when given,
overrides this for that build.
""",
    attrs = {
        "name": attr.string(doc = "The name of a declared SDK.", mandatory = True),
    },
)

def _dependency_requests(registrations):
    """The highest version each dependency requests of the default SDK, by module."""
    requests = {}
    for request in registrations[_DEFAULT_NAME]:
        if request.is_root:
            continue
        known = requests.get(request.module)
        requests[request.module] = newest_version([known, request.version]) if known else request.version
    return requests

def _source_tools(name, rule = dart_sdk_source_tool, **source):
    """Declares the repositories of an SDK's tools built from its source; returns its `tools` parts."""
    tools = {}
    for tool, flag, what in [
        ("kernel", "--@rules_dart//dart:outline_kernel=false", "the outline stripper"),
        ("analyzer", "--@rules_dart//dart:analysis_summaries=false", "the summary analyzer"),
    ]:
        repo = "%s_%s_source" % (name, tool)
        if source:
            rule(name = repo, tool = tool, sdk_name = name, **source)
            tools[tool] = {"repo": repo}
        else:
            tools[tool] = {"error": """\
Dart SDK "{name}" has no source to build {what} from. Give the `DEPS` file at \
the root of its source: dart.custom_sdk(name = "{name}", source = ...). Or build \
without it: {flag}.""".format(name = name, what = what, flag = flag)}
    return tools

def _declare_local_host(name, platform, tag, requests, location, parts, sdk_rule, cross_rule):
    repo = "%s_%s" % (name, platform)
    sdk_rule(
        name = repo,
        sdk_name = name,
        platform = platform,
        build_file_template = dart_local_sdk_build_file(platform),
        requests = requests,
        **location
    )
    parts["hosts"][platform] = {"repo": repo}
    for target in CROSS_TARGETS.get(platform, []):
        cross_repo = "%s_cross_%s" % (repo, target)
        cross_rule(
            name = cross_repo,
            sdk_name = name,
            platform = platform,
            target_platform = target,
            build_file_template = dart_local_cross_sdk_build_file(platform, target),
            cross_tools = tag.cross_tools,
            requests = requests,
            **location
        )
        parts["cross"][cross_pair(platform, target)] = {"repo": cross_repo}

def _local_parts():
    return {"version": "", "hosts": {}, "cross": {}, "tools": {}}

def _declare_custom_sdk(name, tag, requests):
    parts = _local_parts()
    for platform in PLATFORMS.keys():
        if platform in tag.sdk:
            _declare_local_host(name, platform, tag, requests, {"version_file": tag.sdk[platform]}, parts, dart_local_sdk, dart_local_cross_sdk)
            continue
        no_host = {"error": """\
Dart SDK "{name}" has no SDK for {platform}. Add the `version` file of one: \
dart.custom_sdk(name = "{name}", sdk = {{"{platform}": ...}}).""".format(name = name, platform = platform)}
        parts["hosts"][platform] = no_host
        for target in CROSS_TARGETS.get(platform, []):
            parts["cross"][cross_pair(platform, target)] = no_host
    parts["tools"] = _source_tools(name, source = tag.source) if tag.source else _source_tools(name)
    dart_local_sdk_tools(name = name + "_tools", sdk_name = name, version_files = tag.sdk, tools = json.encode(parts["tools"]))
    return parts

def _declare_checkout(name, tag, requests):
    location = {"build_env": tag.build_env, "path_env": tag.path_env, "source": tag.checkout}
    parts = _local_parts()
    for platform in PLATFORMS.keys():
        _declare_local_host(name, platform, tag, requests, location, parts, dart_checkout_sdk, dart_checkout_cross_sdk)
    parts["tools"] = _source_tools(name, rule = dart_checkout_source_tool, source = tag.checkout, path_env = tag.path_env)
    dart_checkout_sdk_tools(name = name + "_tools", sdk_name = name, tools = json.encode(parts["tools"]), **location)
    return parts

def _host_dart(parts, platform):
    """The label of the `dart` an SDK has on `platform`, if a repository holds it."""
    repo = parts["hosts"][platform].get("repo")
    return "@%s//:%s" % (repo, dart_bin(platform)) if repo else None

def _declare_pubspec_reader(sdks, default_sdk):
    """Declares the pubspec reader, compiled by the SDK the project builds with if it can be."""
    project_dart = {}
    if default_sdk != _DEFAULT_NAME:
        for platform in PLATFORMS.keys():
            dart = _host_dart(sdks[default_sdk], platform)
            if dart:
                project_dart[platform] = dart
    pubspec_reader_repositories(
        release_dart = {platform: _host_dart(sdks[_DEFAULT_NAME], platform) for platform in PLATFORMS.keys()},
        project_dart = project_dart,
    )

def _toolchain_extension(module_ctx):
    # The default name is registered whether or not any module requests it.
    registrations = {_DEFAULT_NAME: []}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Dart toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            name_error = sdk_name_error(toolchain.name, 'dart.toolchain(name = "%s")' % toolchain.name)
            if name_error:
                fail(name_error)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.dart_version,
                is_root = mod.is_root,
                module = mod.name,
                allow_upgrade = toolchain.allow_upgrade_by_dependencies,
            ))
    customs = custom_sdks(module_ctx.modules, registrations.keys(), _DEFAULT_NAME)
    if customs.error:
        fail(customs.error)
    default_sdk = customs.use or _DEFAULT_NAME
    requests = _dependency_requests(registrations)

    served = TOOL_VERSIONS.keys()
    newest = newest_version(served)

    # What each SDK is made of, as `toolchains_build_content` takes it.
    sdks = {}

    # The files declared so far: an SDK asking for one again shares its
    # repository. `dart` comes first, so the name a release is stored under,
    # part of Bazel's key for it, is `dart`'s wherever `dart` has that release.
    declared = {}

    # Why an SDK cannot be used, reported when a build uses it: only the flag
    # says which one that is, and the flag is not known here.
    unavailable = {}
    for name, name_requests in registrations.items():
        if name != _DEFAULT_NAME:
            name_requests = named_toolchain_requests(name_requests, requests)
        selection = select_toolchain_version(name, name_requests, newest)
        if selection.error:
            fail(selection.error)
        release = servable_release(selection, served)
        if release.unavailable:
            unavailable[name] = release.unavailable
        sdks[name] = dart_release_repositories(name = name, dart_version = release.version, declared = declared)

    for name, custom in customs.sdks.items():
        tag = custom.tag
        if custom.kind == "release":
            sdks[name] = dart_release_repositories(
                name = name,
                dart_version = tag.dart_version,
                declared = declared,
                sdk_sha256 = tag.sdk_sha256,
                source_sha256 = tag.source_sha256,
                cross_tools_sha256 = tag.cross_tools_sha256,
            )
        elif custom.kind == "custom_sdk":
            sdks[name] = _declare_custom_sdk(name, tag, requests)
        else:
            sdks[name] = _declare_checkout(name, tag, requests)

    # What is known now is checked now, and reported when the SDK is used. Only
    # an SDK's own files know its version otherwise: its repositories check.
    for name, parts in sdks.items():
        if name in unavailable or not parts["version"]:
            continue
        error = sdk_too_old_error(name, parts["version"], requests)
        if error:
            unavailable[name] = error

    _declare_pubspec_reader(sdks, default_sdk)
    dart_host_toolchains(name = "dart_host_toolchains")
    toolchains_repo(
        name = _DEFAULT_NAME + "_toolchains",
        sdks = {name: json.encode(parts) for name, parts in sdks.items()},
        default_sdk = default_sdk,
        unavailable = unavailable,
    )
    return module_ctx.extension_metadata(
        reproducible = True,
    )

dart = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": dart_toolchain,
        "release": dart_release,
        "custom_sdk": dart_custom_sdk,
        "checkout": dart_checkout,
        "use_sdk": dart_use_sdk,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs the Dart SDKs and their toolchains. The module docstring says which SDKs exist and which a build uses.",
)
