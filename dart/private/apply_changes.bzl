"""`bazel run @rules_dart//dart/format` and `@rules_dart//dart/fix`.

Each builds one of the `dart_analyze` aspect's changes groups over the target
patterns it is given, and writes the result into the workspace
(`tools/apply_changes.dart`). The aspect is named by its canonical label, so
the nested build finds it whatever name the user's module gives rules_dart.
"""

load("//dart/private:dart_binary.bzl", "dart_binary")

visibility("//dart/...")

_ASPECT = "%s%%dart_analyze" % Label("//dart:analyze.bzl")

def apply_changes_binary(name, command, output_group):
    """Declares the runnable that writes `output_group`'s changes.

    Args:
      name: The target's name.
      command: The Dart command it stands for, `format` or `fix`.
      output_group: The aspect's output group holding the changes files.
    """
    dart_binary(
        name = name,
        srcs = [
            Label("//dart/private/tools:apply_args.dart"),
            Label("//dart/private/tools:build_events.dart"),
            Label("//dart/private/tools:changes.dart"),
        ],
        args = [
            "--command=" + command,
            "--aspect=" + _ASPECT,
            "--output-group=" + output_group,
        ],
        compile_mode = "exe",
        main = Label("//dart/private/tools:apply_changes.dart"),
        visibility = ["//visibility:public"],
        deps = [Label("@ext_pub_deps//:crypto")],
    )
