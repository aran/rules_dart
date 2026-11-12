"""Rules of another rule set, as the unused-dependency check sees them."""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartUsedWithoutImportInfo")
load("@rules_dart//dart:utils.bzl", "KERNEL_TOOL_ATTR", "PORTABLE_EXEC_GROUPS", "dart_import_check_aspect", "import_check_output_groups")

def _used_without_import_impl(ctx):
    library = ctx.attr.library
    return [library[DefaultInfo], library[DartInfo], DartUsedWithoutImportInfo()]

# A dependency used without an import, as a Flutter plugin is.
used_without_import = rule(
    implementation = _used_without_import_impl,
    attrs = {"library": attr.label(providers = [DartInfo])},
)

def _bootstrapped_impl(ctx):
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".bootstrap.dart")
    ctx.actions.write(bootstrap, "import 'package:import_check_leaf/leaf.dart';\n")
    return [OutputGroupInfo(**import_check_output_groups(
        ctx,
        ctx.executable._kernel_tool,
        ctx.files.srcs,
        None,
        ctx.attr.deps,
        generated = [bootstrap],
    ))]

# An executable whose rule writes a bootstrap importing `leaf`, as a test
# rule's bootstrap imports its test framework.
bootstrapped = rule(
    implementation = _bootstrapped_impl,
    attrs = dict(KERNEL_TOOL_ATTR, **{
        "deps": attr.label_list(providers = [DartInfo], aspects = [dart_import_check_aspect]),
        "srcs": attr.label_list(allow_files = [".dart"]),
    }),
    exec_groups = PORTABLE_EXEC_GROUPS,
)
