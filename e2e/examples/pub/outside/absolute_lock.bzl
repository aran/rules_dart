"""A lock naming a package by its absolute path, as `dart pub get` writes one.

Such a lock holds only on the machine it was written on, so this one is written
where it is used.
"""

def _outside_absolute_lock_impl(rctx):
    package = rctx.workspace_root.dirname.get_child("outside_packages", "outside_greeting")
    rctx.file("pubspec.lock", """\
packages:
  outside_greeting:
    dependency: "direct main"
    description:
      path: "{}"
      relative: false
    source: path
    version: "1.0.0"
sdks:
  dart: ">=3.5.0 <4.0.0"
""".format(package))
    rctx.file("BUILD.bazel", 'exports_files(["pubspec.lock"])\n')

outside_absolute_lock = repository_rule(
    implementation = _outside_absolute_lock_impl,
    local = True,
    doc = "Writes a pubspec.lock naming `outside_greeting` by its absolute path on this machine.",
)
