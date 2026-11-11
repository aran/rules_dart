"""Extensions for bzlmod.

Installs a Dart toolchain.
Every module can define a toolchain version under the default name, "dart", and
every such request is a minimum: no module gets an SDK older than it requested.
Which version is installed depends on the root module:

* If the root module requests a version, that exact version is used. A
  dependency requesting a newer one fails the build, naming the dependency and
  its version. The root either raises its pin to at least that version or sets
  `allow_upgrade_by_dependencies = True` on its `dart.toolchain`, which lets the
  highest of all requests, the root's included, win.
* If the root module requests none, the highest requested version is used.
* The root module may request one version per name; two requests for a name fail.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (each selected by the same rules) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("//dart/private:toolchain_selection.bzl", "select_toolchain_version")
load(":repositories.bzl", "dart_register_toolchains")

_DEFAULT_NAME = "dart"

dart_toolchain = tag_class(
    doc = "Requests a Dart SDK version and registers its toolchains under `name`.",
    attrs = {
        "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Dart toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
        "dart_version": attr.string(doc = """\
Explicit version of the Dart SDK. In the root module it is used exactly, and a
dependency requesting a newer one fails the build unless
`allow_upgrade_by_dependencies` is set. In any other module it is the oldest
SDK the module accepts.
""", mandatory = True),
        "allow_upgrade_by_dependencies": attr.bool(doc = """\
Lets dependencies raise the SDK version: when a module requests a newer Dart SDK
than the root module's `dart_version`, the highest request is used instead of
failing the build. Only the root module may set it.
""", default = False),
    },
)

def _toolchain_extension(module_ctx):
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Dart toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.dart_version,
                is_root = mod.is_root,
                module = mod.name,
                allow_upgrade = toolchain.allow_upgrade_by_dependencies,
            ))
    for name, requests in registrations.items():
        selection = select_toolchain_version(name, requests)
        if selection.error:
            fail(selection.error)

        dart_register_toolchains(
            name = name,
            dart_version = selection.version,
        )
    return module_ctx.extension_metadata(
        reproducible = True,
    )

dart = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {"toolchain": dart_toolchain},
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs a Dart SDK toolchain. Multiple modules may request different versions; the module docstring says which is installed.",
)
