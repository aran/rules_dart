"""Test-only handles on the outputs of a `dart_fix` target.

`dart_fix` produces its fixes tree and its manifest with `declare_directory` /
`declare_file`, so neither is a predeclared output and neither has a label —
nothing outside the rule can name `//pkg:fix.fixes` to hand it to `diff_test`.
Both do reach the outside through the target's runfiles, because that is how
`bazel run` finds them, so these rules recover them from there.

A rule set that expected its users to assert on these would expose them in an
`OutputGroupInfo`; this file exists only because `dart_fix` does not.
"""

_FIXES_SUFFIX = ".fixes"
_MANIFEST_SUFFIX = ".fix_manifest.json"

def _fix_artifacts(target):
    """Recovers a `dart_fix` target's two action outputs from its runfiles.

    Args:
      target: The `dart_fix` Target to inspect.

    Returns:
      A `(fixes_directory, manifest)` tuple of Files.
    """
    fixes = None
    manifest = None
    for f in target[DefaultInfo].default_runfiles.files.to_list():
        if f.basename == target.label.name + _FIXES_SUFFIX:
            fixes = f
        elif f.basename == target.label.name + _MANIFEST_SUFFIX:
            manifest = f
    if fixes == None or manifest == None:
        fail("%s does not carry dart_fix outputs in its runfiles" % target.label)
    return fixes, manifest

def _fix_manifest_impl(ctx):
    _, manifest = _fix_artifacts(ctx.attr.fix)
    return [DefaultInfo(files = depset([manifest]))]

fix_manifest = rule(
    implementation = _fix_manifest_impl,
    attrs = {
        "fix": attr.label(
            doc = "The `dart_fix` target whose manifest becomes this target's output.",
            mandatory = True,
        ),
    },
    doc = "Re-exports a `dart_fix` target's `fix_manifest.json` as a single-file target.",
)

def _fixed_file_impl(ctx):
    fixes, _ = _fix_artifacts(ctx.attr.fix)
    out = ctx.actions.declare_file(ctx.label.name)

    args = ctx.actions.args()
    args.add("--fixes", fixes.path)
    args.add("--out", out)
    args.add_all(ctx.attr.tree_contents, before_each = "--content")
    if ctx.attr.path:
        args.add("--path", ctx.attr.path)

    ctx.actions.run(
        executable = ctx.executable._checker,
        arguments = [args],
        inputs = [fixes],
        outputs = [out],
        mnemonic = "CheckDartFixes",
        progress_message = "Checking dart_fix outputs of %s" % ctx.attr.fix.label,
    )
    return [DefaultInfo(files = depset([out]))]

fixed_file = rule(
    implementation = _fixed_file_impl,
    attrs = {
        "fix": attr.label(
            doc = "The `dart_fix` target whose fixes tree to read.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = (
                "Workspace-relative path of the file to extract from the " +
                "fixes tree. Leave unset to assert on `tree_contents` alone; " +
                "the output is then an empty stamp."
            ),
        ),
        "tree_contents": attr.string_list(
            doc = (
                "The complete set of workspace-relative paths the fixes tree " +
                "must hold. The default asserts the tree is empty. This is " +
                "the assertion that a generated file was never written: an " +
                "extra path fails the build."
            ),
        ),
        "_checker": attr.label(
            default = "//tools:check_fixes",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = (
        "Asserts the exact contents of a `dart_fix` fixes tree, and extracts " +
        "one file from it so `diff_test` can compare it against a golden."
    ),
)
