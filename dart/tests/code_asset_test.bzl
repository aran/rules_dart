"""Analysis tests for `dart_code_asset` attribute validation.

Every invalid `link_mode` / attribute combination is a user-facing contract.
An untested `fail()` is a message nobody has ever read, so each one gets a
case here asserting both that it fires and what it says.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//dart:defs.bzl", "dart_code_asset")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartDsymInfo", "DartLinkInputsInfo")
load("//dart/private:common.bzl", "stage_code_assets")

_ASSET_ID = "package:fixture/src/ffi/fixture.g.dart"
_SHARED_LIB = "//dart/tests/cc_fixture:empty_shared"
_PREBUILT = "//dart/tests/prebuilt_library_fixture:"

def _expect(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

_static_rejected_test = _expect("dart-lang/sdk/issues/49418")
_bundle_needs_library_test = _expect("requires `file`, a `cc_shared_library` or a prebuilt library file")
_bundle_rejects_uri_test = _expect("`uri` is only valid with")
_system_needs_uri_test = _expect("requires `uri =")
_system_rejects_library_test = _expect("`file` is only valid with")
_process_rejects_library_test = _expect("`file` is only valid with")
_executable_rejects_uri_test = _expect("`uri` is only valid with")
_prebuilt_wrong_platform_test = _expect("is not a dynamic library for the target platform")
_system_rejects_prebuilt_test = _expect("`file` is only valid with")
_stated_other_library_test = _expect("but `file` provides")
_stated_library_not_file_test = _expect("`library` must be a File, got string")
_stated_inputs_not_depset_test = _expect("`inputs` must be a depset of Files, got list")
_asset_states_both_test = _expect("states both `link_inputs` and `link_inputs_unset_reason`")
_asset_inputs_not_depset_test = _expect("`link_inputs` must be a depset of Files or None, got list")
_asset_reason_not_string_test = _expect("`link_inputs_unset_reason` must be a string or None, got int")
_asset_gone_with_inputs_test = _expect("states `link_inputs_gone` with `link_inputs`")
_asset_gone_not_bool_test = _expect("`link_inputs_gone` must be a bool, got string")
_stated_gone_with_inputs_test = _expect("DartLinkInputsInfo: states both `inputs` and `gone`")
_stated_neither_test = _expect("DartLinkInputsInfo: states neither `inputs` nor `gone`")
_stated_gone_not_bool_test = _expect("DartLinkInputsInfo: `gone` must be a bool, got string")
_asset_dsym_not_file_test = _expect("`dsym` must be a File or None, got string")
_asset_dsym_not_directory_test = _expect("`dsym` must be a `.dSYM` directory")
_asset_dsym_misnamed_test = _expect("`dsym` must be a `.dSYM` directory")
_asset_dsym_without_file_test = _expect("states `dsym` but has no `file`")
_stated_dsym_other_library_test = _expect("but `file` provides")
_stated_dsym_library_not_file_test = _expect("DartDsymInfo: `library` must be a File, got string")
_stated_dsym_not_directory_test = _expect("`dsym` must be a `.dSYM` directory")
_disagreeing_dsyms_test = _expect("both state the dSYM of")

def _expect_all_impl(ctx):
    env = analysistest.begin(ctx)
    for words in ctx.attr.messages:
        asserts.expect_failure(env, words)
    return analysistest.end(env)

_expect_all_test = analysistest.make(
    _expect_all_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
)

def _prebuilt_carried_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, "dynamic_loading_bundle", info.link_mode)
    asserts.true(env, info.file != None, "no file")
    asserts.equals(env, ctx.attr.basename, info.file.basename)
    return analysistest.end(env)

_prebuilt_carried_test = analysistest.make(
    _prebuilt_carried_impl,
    attrs = {"basename": attr.string()},
)

def _link_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, None, info.link_inputs_unset_reason)
    asserts.equals(env, False, info.link_inputs_gone)
    paths = [f.path for f in info.link_inputs.to_list()]
    for name in ctx.attr.linked:
        asserts.true(env, [p for p in paths if name in p], "%s is not among %s" % (name, paths))
    for name in ctx.attr.not_linked:
        asserts.false(env, [p for p in paths if name in p], "%s is among %s" % (name, paths))
    return analysistest.end(env)

_link_inputs_test = analysistest.make(
    _link_inputs_test_impl,
    attrs = {
        "linked": attr.string_list(),
        "not_linked": attr.string_list(),
    },
)

def _bound_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    library = analysistest.target_under_test(env)[DartCodeAssetInfo].file
    asserts.true(env, ctx.attr.contains in library.basename, "%s lacks %s" % (library.path, ctx.attr.contains))
    asserts.true(env, library.basename.endswith(ctx.attr.suffix), "%s does not end with %s" % (library.path, ctx.attr.suffix))
    return analysistest.end(env)

_bound_library_test = analysistest.make(
    _bound_library_test_impl,
    attrs = {
        "contains": attr.string(),
        "suffix": attr.string(),
    },
)

def _no_link_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, [], info.link_inputs.to_list())
    asserts.equals(env, None, info.link_inputs_unset_reason)
    asserts.equals(env, False, info.link_inputs_gone)
    asserts.equals(env, None, info.dsym)
    return analysistest.end(env)

_no_link_inputs_test = analysistest.make(_no_link_inputs_test_impl)

def _unknown_link_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, None, info.link_inputs)
    asserts.equals(env, ctx.attr.gone, info.link_inputs_gone)
    reason = info.link_inputs_unset_reason
    asserts.true(env, type(reason) == "string" and reason, "no reason: %r" % reason)
    for words in ctx.attr.reason:
        asserts.true(env, words in reason, "%r is not in %r" % (words, reason))
    for words in ctx.attr.not_in_reason:
        asserts.false(env, words in reason, "%r is in %r" % (words, reason))
    return analysistest.end(env)

_unknown_link_inputs_test = analysistest.make(
    _unknown_link_inputs_test_impl,
    attrs = {
        "gone": attr.bool(doc = "Whether the files it was linked from no longer exist."),
        "reason": attr.string_list(),
        "not_in_reason": attr.string_list(),
    },
)

def _dsym_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    dsym = info.dsym
    asserts.true(env, dsym != None, "no dsym")
    if dsym != None:
        asserts.true(env, dsym.is_directory, "%s is no directory" % dsym.path)
        asserts.true(env, dsym.basename.startswith(ctx.attr.of), "%s is not the dSYM of %s" % (dsym.path, ctx.attr.of))
        asserts.true(env, dsym.basename.endswith(".dSYM"), "%s is no dSYM" % dsym.path)
    asserts.equals(env, ctx.attr.link_inputs_known, info.link_inputs != None)
    asserts.equals(env, ctx.attr.gone, info.link_inputs_gone)
    for words in ctx.attr.reason:
        asserts.true(env, words in info.link_inputs_unset_reason, "%r is not in %r" % (words, info.link_inputs_unset_reason))
    return analysistest.end(env)

_DSYM_TEST_ATTRS = {
    "of": attr.string(doc = "What the dSYM's name starts with: the library's."),
    "gone": attr.bool(),
    "link_inputs_known": attr.bool(),
    "reason": attr.string_list(),
}

_dsym_test = analysistest.make(_dsym_test_impl, attrs = _DSYM_TEST_ATTRS)

# A real link under the flag that asks the C++ rules for a dSYM.
_generated_dsym_test = analysistest.make(
    _dsym_test_impl,
    attrs = _DSYM_TEST_ATTRS,
    config_settings = {"//command_line_option:apple_generate_dsym": True},
)

def _no_dsym_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartCodeAssetInfo]
    asserts.equals(env, None, info.dsym)
    return analysistest.end(env)

_no_dsym_test = analysistest.make(_no_dsym_test_impl)

def _stated_asset_impl(ctx):
    kwargs = {}
    if ctx.attr.states == "both":
        kwargs = {"link_inputs": depset(), "link_inputs_unset_reason": "because"}
    elif ctx.attr.states == "inputs_not_depset":
        kwargs = {"link_inputs": []}
    elif ctx.attr.states == "reason_not_string":
        kwargs = {"link_inputs_unset_reason": 1}
    elif ctx.attr.states == "reason_only":
        kwargs = {"link_inputs_unset_reason": "stated by the rule"}
    elif ctx.attr.states == "gone":
        kwargs = {"link_inputs_gone": True}
    elif ctx.attr.states == "gone_reasoned":
        kwargs = {"link_inputs_gone": True, "link_inputs_unset_reason": "deleted by the rule"}
    elif ctx.attr.states == "gone_with_inputs":
        kwargs = {"link_inputs_gone": True, "link_inputs": depset()}
    elif ctx.attr.states == "gone_not_bool":
        kwargs = {"link_inputs_gone": "yes"}
    elif ctx.attr.states == "dsym_not_file":
        kwargs = {"dsym": "libfixture.dylib.dSYM"}
    elif ctx.attr.states == "dsym_not_directory":
        kwargs = {"dsym": ctx.actions.declare_file(ctx.label.name + ".dSYM")}
    elif ctx.attr.states == "dsym_misnamed":
        kwargs = {"dsym": ctx.actions.declare_directory(ctx.label.name)}
    elif ctx.attr.states == "dsym_without_file":
        kwargs = {"dsym": ctx.actions.declare_directory(ctx.label.name + ".dSYM")}
    return [
        DefaultInfo(),
        DartCodeAssetInfo(
            asset_id = _ASSET_ID,
            link_mode = "dynamic_loading_process",
            file = None,
            uri = "",
            **kwargs
        ),
    ]

# A rule of a user's that builds a `DartCodeAssetInfo`, saying about what the
# library was linked from only what `states` picks: nothing at all, or
# something the provider refuses. Only analysed.
_stated_asset = rule(
    implementation = _stated_asset_impl,
    attrs = {"states": attr.string(default = "nothing")},
)

def _copied_library_impl(ctx):
    asset = ctx.attr.asset[DartCodeAssetInfo]
    copy = ctx.actions.declare_file("%s/%s" % (ctx.label.name, asset.file.basename))
    ctx.actions.run_shell(
        inputs = [asset.file],
        outputs = [copy],
        mnemonic = ctx.attr.mnemonic,
        command = 'cp "$1" "$2"',
        arguments = [asset.file.path, copy.path],
    )
    providers = [DefaultInfo(files = depset([copy]))]
    if ctx.attr.states == "copy":
        providers.append(DartLinkInputsInfo(library = copy, inputs = asset.link_inputs))
    elif ctx.attr.states == "original":
        providers.append(DartLinkInputsInfo(library = asset.file, inputs = asset.link_inputs))
    elif ctx.attr.states == "library_not_file":
        providers.append(DartLinkInputsInfo(library = copy.path, inputs = asset.link_inputs))
    elif ctx.attr.states == "inputs_not_depset":
        providers.append(DartLinkInputsInfo(library = copy, inputs = [asset.file]))
    elif ctx.attr.states == "gone":
        providers.append(DartLinkInputsInfo(library = copy, gone = True))
    elif ctx.attr.states == "gone_forwarded":
        # What a rule that forwards the original's link says, either way.
        if asset.link_inputs_gone:
            providers.append(DartLinkInputsInfo(library = copy, gone = True))
        else:
            providers.append(DartLinkInputsInfo(library = copy, inputs = asset.link_inputs))
    elif ctx.attr.states == "gone_with_inputs":
        providers.append(DartLinkInputsInfo(library = copy, inputs = depset(), gone = True))
    elif ctx.attr.states == "neither":
        providers.append(DartLinkInputsInfo(library = copy))
    elif ctx.attr.states == "gone_not_bool":
        providers.append(DartLinkInputsInfo(library = copy, gone = "yes"))
    elif ctx.attr.states == "dsym":
        providers.append(DartDsymInfo(library = copy, dsym = asset.dsym))
    elif ctx.attr.states == "dsym_of_original":
        providers.append(DartDsymInfo(library = asset.file, dsym = asset.dsym))
    elif ctx.attr.states == "dsym_library_not_file":
        providers.append(DartDsymInfo(library = copy.path, dsym = asset.dsym))
    elif ctx.attr.states == "dsym_not_directory":
        providers.append(DartDsymInfo(library = copy, dsym = copy))
    return providers

# A rule of a user's that writes a copy of a code asset's library, saying what
# `states` picks about what it was linked from. Only analysed.
_copied_library = rule(
    implementation = _copied_library_impl,
    attrs = {
        "asset": attr.label(providers = [DartCodeAssetInfo]),
        "mnemonic": attr.string(default = "CopyFile"),
        "states": attr.string(default = "nothing"),
    },
)

def _linked_with_dsym_impl(ctx):
    library = ctx.actions.declare_file("%s/lib%s%s" % (ctx.label.name, ctx.label.name, ctx.attr.suffix))
    dsym = ctx.actions.declare_directory("%s/%s" % (ctx.label.name, ctx.attr.dsym_name or library.basename + ".dSYM"))
    ctx.actions.run_shell(
        outputs = [library, dsym],
        mnemonic = ctx.attr.mnemonic,
        command = "exit 1",
    )
    return [DefaultInfo(files = depset([library]))]

# A rule whose one action writes a library and a dSYM beside it, as rustc does
# under rules_rust and a C++ link does under `--apple_generate_dsym`. Only
# analysed.
_linked_with_dsym = rule(
    implementation = _linked_with_dsym_impl,
    attrs = {
        "dsym_name": attr.string(),
        "mnemonic": attr.string(default = "Rustc"),
        "suffix": attr.string(),
    },
)

def _stating_dsym_sibling_impl(ctx):
    return [
        DefaultInfo(),
        DartDsymInfo(
            library = ctx.attr.of[DefaultInfo].files.to_list()[0],
            dsym = ctx.attr.asset[DartCodeAssetInfo].dsym,
        ),
    ]

# A rule of a user's that provides no file but states that the dSYM of `asset`
# is the dSYM of the first file of `of`.
_stating_dsym_sibling = rule(
    implementation = _stating_dsym_sibling_impl,
    attrs = {
        "asset": attr.label(providers = [DartCodeAssetInfo]),
        "of": attr.label(),
    },
)

def _stating_sibling_impl(ctx):
    library = ctx.attr.of[DefaultInfo].files.to_list()[0]
    if ctx.attr.gone:
        return [DefaultInfo(), DartLinkInputsInfo(library = library, gone = True)]
    return [
        DefaultInfo(),
        DartLinkInputsInfo(library = library, inputs = depset(ctx.files.inputs)),
    ]

# A rule of a user's that provides no file but states what the first file of
# `of` was linked from, as `inputs` or, with `gone`, that those no longer
# exist: a sibling of the target that provides it.
_stating_sibling = rule(
    implementation = _stating_sibling_impl,
    attrs = {
        "gone": attr.bool(),
        "inputs": attr.label_list(allow_files = True),
        "of": attr.label(),
    },
)

# A rule that passes on the files of another target without writing them or
# saying anything about them, as a `filegroup` does, but is no `filegroup`.
_forwarded_files = rule(
    implementation = lambda ctx: [DefaultInfo(files = ctx.attr.of[DefaultInfo].files)],
    attrs = {"of": attr.label()},
)

def _forwarded_shared_impl(ctx):
    info = ctx.attr.of[CcSharedLibraryInfo]
    files = ctx.attr.of[DefaultInfo].files
    providers = [info]
    if ctx.attr.sibling:
        sibling = ctx.actions.declare_file("%s/%s" % (ctx.label.name, ctx.attr.sibling))
        ctx.actions.write(sibling, "")
        files = depset([sibling], transitive = [files])
        if ctx.attr.states:
            library = [lib.dynamic_library for lib in info.linker_input.libraries if lib.dynamic_library][0]
            providers.append(DartLinkInputsInfo(library = library, inputs = depset([sibling])))
    return providers + [DefaultInfo(files = files)]

# A rule that passes on a `cc_shared_library` as a platform transition or a
# wrapper does: its `CcSharedLibraryInfo` and files, with no action linking
# the library. With `sibling`, a file of its own beside the library's, as a
# Windows import library is; with `states`, it says that file is what the
# library was linked from.
_forwarded_shared = rule(
    implementation = _forwarded_shared_impl,
    attrs = {
        "of": attr.label(providers = [CcSharedLibraryInfo]),
        "sibling": attr.string(),
        "states": attr.bool(),
    },
)

def _staged_asset_impl(ctx):
    staged = stage_code_assets(ctx, [ctx.attr.asset[DartCodeAssetInfo]], lambda _index: ctx.label.name)[0]
    return [DefaultInfo(files = depset([staged.file])), staged]

# `stage_code_assets` on one asset: a symlink of its library.
_staged_asset = rule(
    implementation = _staged_asset_impl,
    attrs = {"asset": attr.label(providers = [DartCodeAssetInfo])},
)

# A library of the target platform, and one of another.
_RIGHT_PLATFORM = select({
    "@platforms//os:windows": _PREBUILT + "libwrong.dll",
    "@platforms//os:macos": _PREBUILT + "libwrong.dylib",
    "//conditions:default": _PREBUILT + "libwrong.so",
})
_WRONG_PLATFORM = select({
    "@platforms//os:windows": _PREBUILT + "libwrong.so",
    "//conditions:default": _PREBUILT + "libwrong.dll",
})

# What the target platform names a dynamic library's file.
_LIBRARY_SUFFIX = select({
    "@platforms//os:windows": ".dll",
    "@platforms//os:macos": ".dylib",
    "//conditions:default": ".so",
})

def code_asset_test_suite(name):
    """Declares the `dart_code_asset` validation fixtures and their tests.

    Args:
      name: Name of the generated `test_suite`.
    """

    # `static` is in the attr's `values` (so the rule can produce a useful
    # message) but is rejected by the implementation.
    dart_code_asset(
        name = "ca_static",
        asset_id = _ASSET_ID,
        link_mode = "static",
        file = _SHARED_LIB,
        tags = ["manual"],
    )
    _static_rejected_test(
        name = "static_rejected_test",
        size = "small",
        target_under_test = ":ca_static",
    )

    dart_code_asset(
        name = "ca_bundle_no_library",
        asset_id = _ASSET_ID,
        tags = ["manual"],
    )
    _bundle_needs_library_test(
        name = "bundle_needs_library_test",
        size = "small",
        target_under_test = ":ca_bundle_no_library",
    )

    dart_code_asset(
        name = "ca_bundle_with_uri",
        asset_id = _ASSET_ID,
        file = _SHARED_LIB,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _bundle_rejects_uri_test(
        name = "bundle_rejects_uri_test",
        size = "small",
        target_under_test = ":ca_bundle_with_uri",
    )

    dart_code_asset(
        name = "ca_system_no_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        tags = ["manual"],
    )
    _system_needs_uri_test(
        name = "system_needs_uri_test",
        size = "small",
        target_under_test = ":ca_system_no_uri",
    )

    dart_code_asset(
        name = "ca_system_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        file = _SHARED_LIB,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_library_test(
        name = "system_rejects_library_test",
        size = "small",
        target_under_test = ":ca_system_with_library",
    )

    dart_code_asset(
        name = "ca_process_with_library",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_process",
        file = _SHARED_LIB,
        tags = ["manual"],
    )
    _process_rejects_library_test(
        name = "process_rejects_library_test",
        size = "small",
        target_under_test = ":ca_process_with_library",
    )

    dart_code_asset(
        name = "ca_executable_with_uri",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_executable",
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _executable_rejects_uri_test(
        name = "executable_rejects_uri_test",
        size = "small",
        target_under_test = ":ca_executable_with_uri",
    )

    dart_code_asset(
        name = "ca_prebuilt_wrong_platform",
        asset_id = _ASSET_ID,
        file = _WRONG_PLATFORM,
        tags = ["manual"],
    )
    _prebuilt_wrong_platform_test(
        name = "prebuilt_wrong_platform_test",
        size = "small",
        target_under_test = ":ca_prebuilt_wrong_platform",
    )

    dart_code_asset(
        name = "ca_prebuilt_not_a_library",
        asset_id = _ASSET_ID,
        file = _PREBUILT + "libwrong.txt",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "prebuilt_not_a_library_test",
        size = "small",
        messages = [
            "`file` @@//dart/tests/prebuilt_library_fixture:libwrong.txt: ",
            "libwrong.txt is not a dynamic library for the target platform",
        ],
        target_under_test = ":ca_prebuilt_not_a_library",
    )

    dart_code_asset(
        name = "ca_prebuilt_two_files",
        asset_id = _ASSET_ID,
        file = _PREBUILT + "two_files",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "prebuilt_two_files_test",
        size = "small",
        messages = [
            "nor a single prebuilt library file; it has 2 files",
            "libwrong.dll",
            "libwrong.so",
        ],
        target_under_test = ":ca_prebuilt_two_files",
    )

    dart_code_asset(
        name = "ca_system_with_prebuilt",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        file = _RIGHT_PLATFORM,
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _system_rejects_prebuilt_test(
        name = "system_rejects_prebuilt_test",
        size = "small",
        target_under_test = ":ca_system_with_prebuilt",
    )

    dart_code_asset(
        name = "ca_prebuilt",
        asset_id = _ASSET_ID,
        file = _RIGHT_PLATFORM,
        tags = ["manual"],
    )
    _prebuilt_carried_test(
        name = "prebuilt_carried_test",
        size = "small",
        basename = select({
            "@platforms//os:windows": "libwrong.dll",
            "@platforms//os:macos": "libwrong.dylib",
            "//conditions:default": "libwrong.so",
        }),
        target_under_test = ":ca_prebuilt",
    )

    _no_link_inputs_test(
        name = "prebuilt_no_link_inputs_test",
        size = "small",
        target_under_test = ":ca_prebuilt",
    )

    dart_code_asset(
        name = "ca_system",
        asset_id = _ASSET_ID,
        link_mode = "dynamic_loading_system",
        uri = "libfixture.so.0",
        tags = ["manual"],
    )
    _no_link_inputs_test(
        name = "system_no_link_inputs_test",
        size = "small",
        target_under_test = ":ca_system",
    )

    dart_code_asset(
        name = "ca_linked_shared",
        asset_id = _ASSET_ID,
        file = "//dart/tests/cc_fixture:linked_shared",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "shared_library_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_linked_shared",
    )

    dart_code_asset(
        name = "ca_linked_binary",
        asset_id = _ASSET_ID,
        file = select({
            "@platforms//os:windows": "//dart/tests/cc_fixture:linked_binary.dll",
            "@platforms//os:macos": "//dart/tests/cc_fixture:liblinked_binary.dylib",
            "//conditions:default": "//dart/tests/cc_fixture:liblinked_binary.so",
        }),
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "binary_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
            "exported_cc",
        ],
        target_under_test = ":ca_linked_binary",
    )

    # A `filegroup` adds nothing to the library, so the link behind it is the
    # link of the library.
    native.filegroup(
        name = "linked_shared_files",
        srcs = ["//dart/tests/cc_fixture:linked_shared"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":linked_shared_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "filegroup_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_behind_filegroup",
    )

    native.filegroup(
        name = "linked_shared_files_outer",
        srcs = [":linked_shared_files"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_behind_nested_filegroups",
        asset_id = _ASSET_ID,
        file = ":linked_shared_files_outer",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "nested_filegroups_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_behind_nested_filegroups",
    )

    native.alias(
        name = "linked_shared_alias",
        actual = "//dart/tests/cc_fixture:linked_shared",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_behind_alias",
        asset_id = _ASSET_ID,
        file = ":linked_shared_alias",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "alias_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_behind_alias",
    )

    native.filegroup(
        name = "linked_shared_alias_files",
        srcs = [":linked_shared_alias"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_behind_alias_filegroup",
        asset_id = _ASSET_ID,
        file = ":linked_shared_alias_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "alias_filegroup_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_behind_alias_filegroup",
    )

    native.filegroup(
        name = "linked_binary_files",
        srcs = select({
            "@platforms//os:windows": ["//dart/tests/cc_fixture:linked_binary.dll"],
            "@platforms//os:macos": ["//dart/tests/cc_fixture:liblinked_binary.dylib"],
            "//conditions:default": ["//dart/tests/cc_fixture:liblinked_binary.so"],
        }),
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_binary_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":linked_binary_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "binary_filegroup_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
            "exported_cc",
        ],
        target_under_test = ":ca_binary_behind_filegroup",
    )

    # A filegroup binds the library of the `cc_shared_library` it wraps only
    # when it provides that library and nothing but the library target's own
    # outputs, as an import library and a `.pdb` are on Windows. Here a target
    # of the library's own, with a file beside it, stands in for them, on every
    # platform.
    _forwarded_shared(
        name = "shared_with_sibling",
        of = "//dart/tests/cc_fixture:linked_shared",
        sibling = "linked_shared.sibling",
        states = True,
        tags = ["manual"],
    )
    native.filegroup(
        name = "shared_with_sibling_files",
        srcs = [":shared_with_sibling"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_shared_with_sibling",
        asset_id = _ASSET_ID,
        file = ":shared_with_sibling_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "shared_with_sibling_link_inputs_test",
        size = "small",
        linked = ["linked_shared.sibling"],
        target_under_test = ":ca_shared_with_sibling",
    )
    _bound_library_test(
        name = "shared_with_sibling_library_test",
        size = "small",
        contains = "linked_shared",
        suffix = _LIBRARY_SUFFIX,
        target_under_test = ":ca_shared_with_sibling",
    )

    # A text file beside the library in the filegroup is not an output of the
    # library: it is not bound as if it were not there. Nor is a library of
    # another origin.
    native.filegroup(
        name = "linked_shared_with_extra_files",
        srcs = [
            "//dart/tests/cc_fixture:linked_shared",
            _PREBUILT + "libwrong.txt",
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_shared_with_extra_files",
        asset_id = _ASSET_ID,
        file = ":linked_shared_with_extra_files",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "shared_with_extra_files_test",
        size = "small",
        messages = [
            "nor a single prebuilt library file; it has 2 files",
            "libwrong.txt",
            "linked_shared",
        ],
        target_under_test = ":ca_shared_with_extra_files",
    )

    native.filegroup(
        name = "linked_shared_with_other_library",
        srcs = ["//dart/tests/cc_fixture:linked_shared"] + select({
            "@platforms//os:windows": [_PREBUILT + "libwrong.dll"],
            "@platforms//os:macos": [_PREBUILT + "libwrong.dylib"],
            "//conditions:default": [_PREBUILT + "libwrong.so"],
        }),
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_shared_with_other_library",
        asset_id = _ASSET_ID,
        file = ":linked_shared_with_other_library",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "shared_with_other_library_test",
        size = "small",
        messages = [
            "nor a single prebuilt library file; it has 2 files",
            "libwrong.",
            "linked_shared",
        ],
        target_under_test = ":ca_shared_with_other_library",
    )

    # An output group that is not the library: the filegroup does not provide
    # it, so there is nothing to bind it by.
    native.filegroup(
        name = "linked_shared_pdb",
        srcs = ["//dart/tests/cc_fixture:linked_shared"],
        output_group = "pdb_file",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_shared_pdb",
        asset_id = _ASSET_ID,
        file = ":linked_shared_pdb",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "shared_pdb_test",
        size = "small",
        messages = ["ca_shared_pdb: `file` ", "linked_shared_pdb"],
        target_under_test = ":ca_shared_pdb",
    )

    # An output group that is the library, beside a file of no output group:
    # the filegroup provides just the library.
    native.filegroup(
        name = "linked_shared_main_output",
        srcs = [
            "//dart/tests/cc_fixture:linked_shared",
            _PREBUILT + "libwrong.txt",
        ],
        output_group = "main_shared_library_output",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_shared_main_output",
        asset_id = _ASSET_ID,
        file = ":linked_shared_main_output",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "shared_main_output_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_shared_main_output",
    )
    _bound_library_test(
        name = "shared_main_output_library_test",
        size = "small",
        contains = "linked_shared",
        suffix = _LIBRARY_SUFFIX,
        target_under_test = ":ca_shared_main_output",
    )

    # A `cc_shared_library` passed on without a link of its own: the library
    # is bound all the same, and what it was linked from is not known.
    _forwarded_shared(
        name = "forwarded_shared",
        of = "//dart/tests/cc_fixture:linked_shared",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_shared",
        asset_id = _ASSET_ID,
        file = ":forwarded_shared",
        tags = ["manual"],
    )
    _bound_library_test(
        name = "forwarded_shared_library_test",
        size = "small",
        contains = "linked_shared",
        suffix = _LIBRARY_SUFFIX,
        target_under_test = ":ca_forwarded_shared",
    )
    _unknown_link_inputs_test(
        name = "forwarded_shared_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_forwarded_shared",
            ":forwarded_shared",
            "did not write",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_forwarded_shared",
    )

    native.filegroup(
        name = "forwarded_shared_files",
        srcs = [":forwarded_shared"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_shared_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":forwarded_shared_files",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "forwarded_shared_filegroup_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_forwarded_shared_behind_filegroup",
            ":forwarded_shared_files",
            "did not write",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_forwarded_shared_behind_filegroup",
    )

    # ... unless the target says what it was linked from.
    _forwarded_shared(
        name = "forwarded_shared_stating",
        of = "//dart/tests/cc_fixture:linked_shared",
        sibling = "linked_shared.stated",
        states = True,
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_shared_stating",
        asset_id = _ASSET_ID,
        file = ":forwarded_shared_stating",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "forwarded_shared_stating_link_inputs_test",
        size = "small",
        linked = ["linked_shared.stated"],
        target_under_test = ":ca_forwarded_shared_stating",
    )

    native.filegroup(
        name = "two_shared_libraries",
        srcs = [
            "//dart/tests/cc_fixture:linked_shared",
            _SHARED_LIB,
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_two_shared_libraries",
        asset_id = _ASSET_ID,
        file = ":two_shared_libraries",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "two_shared_libraries_test",
        size = "small",
        messages = [
            "wraps 2 shared libraries",
            "cc_fixture:linked_shared",
            "cc_fixture:empty_shared",
        ],
        target_under_test = ":ca_two_shared_libraries",
    )

    # Only a `filegroup` is looked through: a rule that forwards the files
    # itself may have changed them.
    _forwarded_files(
        name = "forwarded_files",
        of = "//dart/tests/cc_fixture:linked_shared",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_files",
        asset_id = _ASSET_ID,
        file = ":forwarded_files",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "forwarded_files_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_forwarded_files",
            ":forwarded_files",
            "did not write",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_forwarded_files",
    )

    # A prebuilt library has no link, behind a filegroup as well.
    native.filegroup(
        name = "prebuilt_files",
        srcs = select({
            "@platforms//os:windows": [_PREBUILT + "libwrong.dll"],
            "@platforms//os:macos": [_PREBUILT + "libwrong.dylib"],
            "//conditions:default": [_PREBUILT + "libwrong.so"],
        }),
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_prebuilt_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":prebuilt_files",
        tags = ["manual"],
    )
    _no_link_inputs_test(
        name = "prebuilt_filegroup_no_link_inputs_test",
        size = "small",
        target_under_test = ":ca_prebuilt_behind_filegroup",
    )

    # A copy's action is no link: its inputs are the library, not the objects.
    _copied_library(
        name = "copied_library",
        asset = ":ca_linked_shared",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_copied",
        asset_id = _ASSET_ID,
        file = ":copied_library",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "copy_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_copied",
            ":copied_library",
            "`CopyFile`",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_copied",
    )

    native.filegroup(
        name = "copied_library_files",
        srcs = [":copied_library"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_copied_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":copied_library_files",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "copy_filegroup_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_copied_behind_filegroup",
            ":copied_library_files",
            "`CopyFile`",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_copied_behind_filegroup",
    )

    # rules_rust's `Rustc` action writes a Rust library, and is no link either:
    # its object file is made and deleted inside it.
    _copied_library(
        name = "rustc_library",
        asset = ":ca_linked_shared",
        mnemonic = "Rustc",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_rustc",
        asset_id = _ASSET_ID,
        file = ":rustc_library",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "rustc_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_rustc",
            ":rustc_library",
            "`Rustc`",
            "deletes inside that action",
            "no longer exist",
        ],
        # This one wrote no dSYM, so there is none to point at; and there is
        # no target to name that would bring the objects back.
        not_in_reason = [
            "dsym",
            "dSYM",
            "DartLinkInputsInfo",
        ],
        gone = True,
        target_under_test = ":ca_rustc",
    )

    _copied_library(
        name = "forwarding_library",
        asset = ":ca_linked_shared",
        states = "copy",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded",
        asset_id = _ASSET_ID,
        file = ":forwarding_library",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "forwarded_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_forwarded",
    )

    native.filegroup(
        name = "forwarding_library_files",
        srcs = [":forwarding_library"],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_behind_filegroup",
        asset_id = _ASSET_ID,
        file = ":forwarding_library_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "forwarded_filegroup_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":ca_forwarded_behind_filegroup",
    )

    # Only what a wrapped target states about the bound library counts: a
    # sibling that states another file is not in the way, whichever is first.
    _stating_sibling(
        name = "unrelated_statement",
        inputs = [_PREBUILT + "libwrong.txt"],
        of = _SHARED_LIB,
        tags = ["manual"],
    )
    native.filegroup(
        name = "forwarded_with_sibling_files",
        srcs = [
            ":unrelated_statement",
            ":forwarding_library",
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_with_sibling",
        asset_id = _ASSET_ID,
        file = ":forwarded_with_sibling_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "sibling_statement_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = [
            "exported_cc",
            "libwrong",
        ],
        target_under_test = ":ca_forwarded_with_sibling",
    )

    native.filegroup(
        name = "linked_with_sibling_files",
        srcs = [
            "//dart/tests/cc_fixture:linked_shared",
            ":unrelated_statement",
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_linked_with_sibling",
        asset_id = _ASSET_ID,
        file = ":linked_with_sibling_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "sibling_statement_over_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = [
            "exported_cc",
            "libwrong",
        ],
        target_under_test = ":ca_linked_with_sibling",
    )

    # Two targets stating the one library differently: one of them is wrong.
    _stating_sibling(
        name = "conflicting_statement",
        inputs = [_PREBUILT + "libwrong.txt"],
        of = ":forwarding_library",
        tags = ["manual"],
    )
    native.filegroup(
        name = "conflicting_files",
        srcs = [
            ":forwarding_library",
            ":conflicting_statement",
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_conflicting",
        asset_id = _ASSET_ID,
        file = ":conflicting_files",
        tags = ["manual"],
    )
    _expect_all_test(
        name = "disagreeing_statements_test",
        size = "small",
        messages = [
            "disagree",
            ":forwarding_library",
            ":conflicting_statement",
            ":ca_conflicting",
        ],
        target_under_test = ":ca_conflicting",
    )

    # The same statement reached twice is one statement.
    native.filegroup(
        name = "forwarded_twice_files",
        srcs = [
            ":forwarding_library",
            ":forwarding_library_files",
        ],
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_forwarded_twice",
        asset_id = _ASSET_ID,
        file = ":forwarded_twice_files",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "statement_reached_twice_link_inputs_test",
        size = "small",
        linked = ["linked_root"],
        target_under_test = ":ca_forwarded_twice",
    )

    # Staging a library for a program links it, and it is the same library.
    _staged_asset(
        name = "staged_linked",
        asset = ":ca_behind_filegroup",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "staged_link_inputs_test",
        size = "small",
        linked = [
            "linked_root",
            "linked_dep",
        ],
        not_linked = ["exported_cc"],
        target_under_test = ":staged_linked",
    )
    _staged_asset(
        name = "staged_unknown",
        asset = ":ca_copied",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "staged_unknown_link_inputs_test",
        size = "small",
        reason = [
            ":ca_copied",
            "`CopyFile`",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":staged_unknown",
    )

    # What a rule states wins over the action writing the library, even one
    # that counts as a link: this one's only input is the original library.
    _copied_library(
        name = "stating_linker",
        asset = ":ca_linked_shared",
        mnemonic = "CppLink",
        states = "copy",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_stating_linker",
        asset_id = _ASSET_ID,
        file = ":stating_linker",
        tags = ["manual"],
    )
    _link_inputs_test(
        name = "stated_over_action_link_inputs_test",
        size = "small",
        linked = ["linked_root"],
        target_under_test = ":ca_stating_linker",
    )

    _copied_library(
        name = "states_other_library",
        asset = ":ca_linked_shared",
        states = "original",
        tags = ["manual"],
    )
    dart_code_asset(
        name = "ca_states_other_library",
        asset_id = _ASSET_ID,
        file = ":states_other_library",
        tags = ["manual"],
    )
    _stated_other_library_test(
        name = "stated_other_library_test",
        size = "small",
        target_under_test = ":ca_states_other_library",
    )

    _copied_library(
        name = "states_library_not_file",
        asset = ":ca_linked_shared",
        states = "library_not_file",
        tags = ["manual"],
    )
    _stated_library_not_file_test(
        name = "stated_library_not_file_test",
        size = "small",
        target_under_test = ":states_library_not_file",
    )

    _copied_library(
        name = "states_inputs_not_depset",
        asset = ":ca_linked_shared",
        states = "inputs_not_depset",
        tags = ["manual"],
    )
    _stated_inputs_not_depset_test(
        name = "stated_inputs_not_depset_test",
        size = "small",
        target_under_test = ":states_inputs_not_depset",
    )

    # A rule that says nothing about it gets a reason that says so and what to do.
    _stated_asset(
        name = "silent_asset",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "silent_asset_unknown_link_inputs_test",
        size = "small",
        reason = [
            "did not state what",
            "was linked from",
            "`link_inputs`",
            "`dart_code_asset`",
        ],
        target_under_test = ":silent_asset",
    )

    # A rule that states why it cannot say keeps its own words.
    _stated_asset(
        name = "reasoned_asset",
        states = "reason_only",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "reasoned_asset_unknown_link_inputs_test",
        size = "small",
        reason = ["stated by the rule"],
        target_under_test = ":reasoned_asset",
    )

    # One fact, one way: known inputs have no reason for being unknown.
    _stated_asset(
        name = "asset_states_both",
        states = "both",
        tags = ["manual"],
    )
    _asset_states_both_test(
        name = "asset_states_both_test",
        size = "small",
        target_under_test = ":asset_states_both",
    )
    _stated_asset(
        name = "asset_inputs_not_depset",
        states = "inputs_not_depset",
        tags = ["manual"],
    )
    _asset_inputs_not_depset_test(
        name = "asset_inputs_not_depset_test",
        size = "small",
        target_under_test = ":asset_inputs_not_depset",
    )
    _stated_asset(
        name = "asset_reason_not_string",
        states = "reason_not_string",
        tags = ["manual"],
    )
    _asset_reason_not_string_test(
        name = "asset_reason_not_string_test",
        size = "small",
        target_under_test = ":asset_reason_not_string",
    )

    _dsym_tests()
    _gone_tests()

    native.test_suite(
        name = name,
        tests = _DSYM_TESTS + _GONE_TESTS + [
            ":silent_asset_unknown_link_inputs_test",
            ":reasoned_asset_unknown_link_inputs_test",
            ":asset_states_both_test",
            ":asset_inputs_not_depset_test",
            ":asset_reason_not_string_test",
            ":filegroup_link_inputs_test",
            ":shared_with_sibling_link_inputs_test",
            ":shared_with_sibling_library_test",
            ":shared_with_extra_files_test",
            ":shared_with_other_library_test",
            ":shared_pdb_test",
            ":shared_main_output_link_inputs_test",
            ":shared_main_output_library_test",
            ":forwarded_shared_library_test",
            ":forwarded_shared_unknown_link_inputs_test",
            ":forwarded_shared_filegroup_unknown_link_inputs_test",
            ":forwarded_shared_stating_link_inputs_test",
            ":two_shared_libraries_test",
            ":nested_filegroups_link_inputs_test",
            ":alias_link_inputs_test",
            ":alias_filegroup_link_inputs_test",
            ":binary_filegroup_link_inputs_test",
            ":forwarded_files_unknown_link_inputs_test",
            ":prebuilt_filegroup_no_link_inputs_test",
            ":copy_filegroup_unknown_link_inputs_test",
            ":rustc_unknown_link_inputs_test",
            ":forwarded_filegroup_link_inputs_test",
            ":sibling_statement_link_inputs_test",
            ":sibling_statement_over_link_inputs_test",
            ":disagreeing_statements_test",
            ":statement_reached_twice_link_inputs_test",
            ":staged_link_inputs_test",
            ":staged_unknown_link_inputs_test",
            ":copy_unknown_link_inputs_test",
            ":forwarded_link_inputs_test",
            ":stated_over_action_link_inputs_test",
            ":stated_other_library_test",
            ":stated_library_not_file_test",
            ":stated_inputs_not_depset_test",
            ":prebuilt_no_link_inputs_test",
            ":system_no_link_inputs_test",
            ":shared_library_link_inputs_test",
            ":binary_link_inputs_test",
            ":prebuilt_wrong_platform_test",
            ":prebuilt_not_a_library_test",
            ":prebuilt_two_files_test",
            ":system_rejects_prebuilt_test",
            ":prebuilt_carried_test",
            ":static_rejected_test",
            ":bundle_needs_library_test",
            ":bundle_rejects_uri_test",
            ":system_needs_uri_test",
            ":system_rejects_library_test",
            ":process_rejects_library_test",
            ":executable_rejects_uri_test",
        ],
    )

_DSYM_TESTS = [
    ":rustc_dsym_test",
    ":link_dsym_test",
    ":generated_dsym_test",
    ":filegroup_dsym_test",
    ":staged_dsym_test",
    ":other_name_no_dsym_test",
    ":forwarded_files_no_dsym_test",
    ":shared_library_no_dsym_test",
    ":copy_no_dsym_test",
    ":copy_no_dsym_reason_test",
    ":copy_stated_dsym_test",
    ":copy_stated_dsym_filegroup_test",
    ":sibling_stated_dsym_test",
    ":other_file_statement_no_dsym_test",
    ":disagreeing_dsyms_test",
    ":stated_dsym_other_library_test",
    ":stated_dsym_library_not_file_test",
    ":stated_dsym_not_directory_test",
    ":asset_dsym_not_file_test",
    ":asset_dsym_not_directory_test",
    ":asset_dsym_misnamed_test",
    ":asset_dsym_without_file_test",
]

def _dsym_asset(name, file):
    dart_code_asset(
        name = name,
        asset_id = _ASSET_ID,
        file = file,
        tags = ["manual"],
    )

def _dsym_tests():
    # rustc writes the library and its dSYM in one action, and deletes the
    # object file between them: the dSYM is the only way to its line tables.
    _linked_with_dsym(
        name = "rust_library",
        suffix = _LIBRARY_SUFFIX,
        tags = ["manual"],
    )
    _dsym_asset("ca_rust", ":rust_library")
    _dsym_test(
        name = "rustc_dsym_test",
        size = "small",
        gone = True,
        of = "librust_library",
        reason = [
            "`Rustc`",
            "`dsym`",
        ],
        target_under_test = ":ca_rust",
    )

    # A link that writes one has both: the dSYM, and what dsymutil would read.
    _linked_with_dsym(
        name = "linked_with_dsym",
        mnemonic = "CppLink",
        suffix = _LIBRARY_SUFFIX,
        tags = ["manual"],
    )
    _dsym_asset("ca_linked_with_dsym", ":linked_with_dsym")
    _dsym_test(
        name = "link_dsym_test",
        size = "small",
        link_inputs_known = True,
        of = "liblinked_with_dsym",
        target_under_test = ":ca_linked_with_dsym",
    )

    # The real thing: `cc_binary` under `--apple_generate_dsym`.
    dart_code_asset(
        name = "ca_generated_dsym",
        asset_id = _ASSET_ID,
        file = "//dart/tests/cc_fixture:liblinked_binary.dylib",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _generated_dsym_test(
        name = "generated_dsym_test",
        size = "small",
        link_inputs_known = True,
        of = "liblinked_binary.dylib",
        target_compatible_with = ["@platforms//os:macos"],
        target_under_test = ":ca_generated_dsym",
    )

    native.filegroup(
        name = "rust_library_files",
        srcs = [":rust_library"],
        tags = ["manual"],
    )
    native.filegroup(
        name = "rust_library_files_again",
        srcs = [":rust_library_files"],
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_filegroup", ":rust_library_files_again")
    _dsym_test(
        name = "filegroup_dsym_test",
        size = "small",
        gone = True,
        of = "librust_library",
        target_under_test = ":ca_rust_filegroup",
    )

    # The staged library is a symlink of the one the dSYM describes.
    _staged_asset(
        name = "staged_rust",
        asset = ":ca_rust",
        tags = ["manual"],
    )
    _dsym_test(
        name = "staged_dsym_test",
        size = "small",
        gone = True,
        of = "librust_library",
        target_under_test = ":staged_rust",
    )

    # An action's other directories are not this library's dSYM.
    _linked_with_dsym(
        name = "other_name",
        dsym_name = "libother.dylib.dSYM",
        suffix = _LIBRARY_SUFFIX,
        tags = ["manual"],
    )
    _dsym_asset("ca_other_name", ":other_name")
    _no_dsym_test(
        name = "other_name_no_dsym_test",
        size = "small",
        target_under_test = ":ca_other_name",
    )

    # A rule that is no `filegroup` hides the action that wrote the library.
    _forwarded_files(
        name = "forwarded_rust_library",
        of = ":rust_library",
        tags = ["manual"],
    )
    _dsym_asset("ca_forwarded_rust", ":forwarded_rust_library")
    _no_dsym_test(
        name = "forwarded_files_no_dsym_test",
        size = "small",
        target_under_test = ":ca_forwarded_rust",
    )

    _no_dsym_test(
        name = "shared_library_no_dsym_test",
        size = "small",
        target_under_test = ":ca_linked_shared",
    )

    # A copy is the same code, but only its rule can say so.
    _copied_library(
        name = "rust_copy",
        asset = ":ca_rust",
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy", ":rust_copy")
    _no_dsym_test(
        name = "copy_no_dsym_test",
        size = "small",
        target_under_test = ":ca_rust_copy",
    )
    _unknown_link_inputs_test(
        name = "copy_no_dsym_reason_test",
        size = "small",
        not_in_reason = ["`dsym`"],
        target_under_test = ":ca_rust_copy",
    )

    _copied_library(
        name = "rust_copy_stating",
        asset = ":ca_rust",
        states = "dsym",
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_stating", ":rust_copy_stating")
    _dsym_test(
        name = "copy_stated_dsym_test",
        size = "small",
        of = "librust_library",
        reason = [
            "`CopyFile`",
            "`dsym`",
        ],
        target_under_test = ":ca_rust_copy_stating",
    )
    native.filegroup(
        name = "rust_copy_stating_files",
        srcs = [":rust_copy_stating"],
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_stating_filegroup", ":rust_copy_stating_files")
    _dsym_test(
        name = "copy_stated_dsym_filegroup_test",
        size = "small",
        of = "librust_library",
        target_under_test = ":ca_rust_copy_stating_filegroup",
    )

    # Behind a `filegroup`, a sibling may state it, and statements about other
    # files are none of this library's concern.
    _stating_dsym_sibling(
        name = "dsym_sibling",
        asset = ":ca_rust",
        of = ":rust_copy",
        tags = ["manual"],
    )
    native.filegroup(
        name = "rust_copy_with_sibling",
        srcs = [
            ":dsym_sibling",
            ":rust_copy",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_with_sibling", ":rust_copy_with_sibling")
    _dsym_test(
        name = "sibling_stated_dsym_test",
        size = "small",
        of = "librust_library",
        target_under_test = ":ca_rust_copy_with_sibling",
    )

    _stating_dsym_sibling(
        name = "dsym_sibling_of_other_file",
        asset = ":ca_rust",
        of = ":copied_library",
        tags = ["manual"],
    )
    native.filegroup(
        name = "rust_copy_with_other_statement",
        srcs = [
            ":dsym_sibling_of_other_file",
            ":rust_copy",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_with_other_statement", ":rust_copy_with_other_statement")
    _no_dsym_test(
        name = "other_file_statement_no_dsym_test",
        size = "small",
        target_under_test = ":ca_rust_copy_with_other_statement",
    )

    _stating_dsym_sibling(
        name = "disagreeing_dsym_sibling",
        asset = ":ca_linked_with_dsym",
        of = ":rust_copy",
        tags = ["manual"],
    )
    native.filegroup(
        name = "rust_copy_disagreeing",
        srcs = [
            ":disagreeing_dsym_sibling",
            ":dsym_sibling",
            ":rust_copy",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_disagreeing", ":rust_copy_disagreeing")
    _disagreeing_dsyms_test(
        name = "disagreeing_dsyms_test",
        size = "small",
        target_under_test = ":ca_rust_copy_disagreeing",
    )

    _copied_library(
        name = "rust_copy_stating_original",
        asset = ":ca_rust",
        states = "dsym_of_original",
        tags = ["manual"],
    )
    _dsym_asset("ca_rust_copy_stating_original", ":rust_copy_stating_original")
    _stated_dsym_other_library_test(
        name = "stated_dsym_other_library_test",
        size = "small",
        target_under_test = ":ca_rust_copy_stating_original",
    )
    _copied_library(
        name = "dsym_library_not_file",
        asset = ":ca_rust",
        states = "dsym_library_not_file",
        tags = ["manual"],
    )
    _stated_dsym_library_not_file_test(
        name = "stated_dsym_library_not_file_test",
        size = "small",
        target_under_test = ":dsym_library_not_file",
    )
    _copied_library(
        name = "dsym_statement_not_directory",
        asset = ":ca_rust",
        states = "dsym_not_directory",
        tags = ["manual"],
    )
    _stated_dsym_not_directory_test(
        name = "stated_dsym_not_directory_test",
        size = "small",
        target_under_test = ":dsym_statement_not_directory",
    )

    for states, test in [
        ("dsym_not_file", _asset_dsym_not_file_test),
        ("dsym_not_directory", _asset_dsym_not_directory_test),
        ("dsym_misnamed", _asset_dsym_misnamed_test),
        ("dsym_without_file", _asset_dsym_without_file_test),
    ]:
        _stated_asset(
            name = "asset_" + states,
            states = states,
            tags = ["manual"],
        )
        test(
            name = "asset_%s_test" % states,
            size = "small",
            target_under_test = ":asset_" + states,
        )

_GONE_TESTS = [
    ":rustc_filegroup_gone_test",
    ":forwarded_rustc_not_gone_test",
    ":rustc_copy_not_gone_test",
    ":rustc_copy_stating_gone_test",
    ":rustc_copy_stating_gone_filegroup_test",
    ":rustc_copy_stating_known_link_inputs_test",
    ":sibling_stating_gone_test",
    ":disagreeing_gone_statements_test",
    ":gone_statement_reached_twice_test",
    ":staged_gone_test",
    ":silent_asset_not_gone_test",
    ":gone_asset_test",
    ":reasoned_gone_asset_test",
    ":asset_gone_with_inputs_test",
    ":asset_gone_not_bool_test",
    ":stated_gone_with_inputs_test",
    ":stated_neither_test",
    ":stated_gone_not_bool_test",
]

def _gone_tests():
    # `Rustc` deletes the objects it links inside the action, so they are gone,
    # not merely out of sight; a `filegroup` around it, nested ones included,
    # shows the action as it shows any other.
    native.filegroup(
        name = "rustc_library_files",
        srcs = [":rustc_library"],
        tags = ["manual"],
    )
    native.filegroup(
        name = "rustc_library_files_again",
        srcs = [":rustc_library_files"],
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_behind_filegroup", ":rustc_library_files_again")
    _unknown_link_inputs_test(
        name = "rustc_filegroup_gone_test",
        size = "small",
        gone = True,
        reason = [
            ":rustc_library_files_again",
            "`Rustc`",
            "no longer exist",
        ],
        target_under_test = ":ca_rustc_behind_filegroup",
    )

    # A rule that is no `filegroup` hides the action: the link is out of sight,
    # which naming the right target mends, so it is not gone.
    _forwarded_files(
        name = "forwarded_rustc_library",
        of = ":rustc_library",
        tags = ["manual"],
    )
    _dsym_asset("ca_forwarded_rustc_library", ":forwarded_rustc_library")
    _unknown_link_inputs_test(
        name = "forwarded_rustc_not_gone_test",
        size = "small",
        not_in_reason = [
            "`Rustc`",
            "no longer exist",
        ],
        reason = ["did not write it"],
        target_under_test = ":ca_forwarded_rustc_library",
    )

    # A copy of it is a copy: only its rule can say what became of the objects.
    _copied_library(
        name = "rustc_copy",
        asset = ":ca_rustc",
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_copy", ":rustc_copy")
    _unknown_link_inputs_test(
        name = "rustc_copy_not_gone_test",
        size = "small",
        not_in_reason = ["no longer exist"],
        reason = [
            "`CopyFile`",
            "DartLinkInputsInfo",
        ],
        target_under_test = ":ca_rustc_copy",
    )

    # A copy that says so is gone; one that forwards inputs which are known is not.
    _copied_library(
        name = "rustc_copy_stating",
        asset = ":ca_rustc",
        states = "gone_forwarded",
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_copy_stating", ":rustc_copy_stating")
    _unknown_link_inputs_test(
        name = "rustc_copy_stating_gone_test",
        size = "small",
        gone = True,
        reason = [
            ":rustc_copy_stating",
            "says its objects were deleted",
            "no longer exist",
        ],
        target_under_test = ":ca_rustc_copy_stating",
    )
    native.filegroup(
        name = "rustc_copy_stating_files",
        srcs = [":rustc_copy_stating"],
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_copy_stating_filegroup", ":rustc_copy_stating_files")
    _unknown_link_inputs_test(
        name = "rustc_copy_stating_gone_filegroup_test",
        size = "small",
        gone = True,
        reason = ["no longer exist"],
        target_under_test = ":ca_rustc_copy_stating_filegroup",
    )
    _copied_library(
        name = "linked_copy_stating",
        asset = ":ca_linked_shared",
        states = "gone_forwarded",
        tags = ["manual"],
    )
    _dsym_asset("ca_linked_copy_stating", ":linked_copy_stating")
    _link_inputs_test(
        name = "rustc_copy_stating_known_link_inputs_test",
        size = "small",
        linked = ["linked_root"],
        target_under_test = ":ca_linked_copy_stating",
    )

    # Behind a `filegroup`, a sibling may state it.
    _stating_sibling(
        name = "gone_sibling",
        gone = True,
        of = ":rustc_copy",
        tags = ["manual"],
    )
    native.filegroup(
        name = "rustc_copy_with_gone_sibling",
        srcs = [
            ":gone_sibling",
            ":rustc_copy",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_copy_with_gone_sibling", ":rustc_copy_with_gone_sibling")
    _unknown_link_inputs_test(
        name = "sibling_stating_gone_test",
        size = "small",
        gone = True,
        reason = ["no longer exist"],
        target_under_test = ":ca_rustc_copy_with_gone_sibling",
    )

    # Gone and known are different statements, and two of them disagree.
    _stating_sibling(
        name = "known_sibling",
        inputs = [_PREBUILT + "libwrong.txt"],
        of = ":rustc_copy_stating",
        tags = ["manual"],
    )
    native.filegroup(
        name = "rustc_copy_disagreeing_files",
        srcs = [
            ":rustc_copy_stating",
            ":known_sibling",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_rustc_copy_disagreeing", ":rustc_copy_disagreeing_files")
    _expect_all_test(
        name = "disagreeing_gone_statements_test",
        size = "small",
        messages = [
            "disagree",
            ":rustc_copy_stating",
            ":known_sibling",
        ],
        target_under_test = ":ca_rustc_copy_disagreeing",
    )

    # The same statement reached twice is one statement.
    native.filegroup(
        name = "gone_twice_files",
        srcs = [
            ":rustc_copy_stating",
            ":rustc_copy_stating_files",
        ],
        tags = ["manual"],
    )
    _dsym_asset("ca_gone_twice", ":gone_twice_files")
    _unknown_link_inputs_test(
        name = "gone_statement_reached_twice_test",
        size = "small",
        gone = True,
        target_under_test = ":ca_gone_twice",
    )

    # Staging a library for a program links it, and it is the same library.
    _staged_asset(
        name = "staged_rustc",
        asset = ":ca_rustc",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "staged_gone_test",
        size = "small",
        gone = True,
        reason = ["`Rustc`"],
        target_under_test = ":staged_rustc",
    )

    # A rule building the provider itself: nothing stated is not gone, gone
    # needs no words of its own but keeps them when given, and gone is no
    # company for files that are known.
    _unknown_link_inputs_test(
        name = "silent_asset_not_gone_test",
        size = "small",
        not_in_reason = ["no longer exist"],
        target_under_test = ":silent_asset",
    )
    _stated_asset(
        name = "gone_asset",
        states = "gone",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "gone_asset_test",
        size = "small",
        gone = True,
        reason = ["no longer exist"],
        target_under_test = ":gone_asset",
    )
    _stated_asset(
        name = "reasoned_gone_asset",
        states = "gone_reasoned",
        tags = ["manual"],
    )
    _unknown_link_inputs_test(
        name = "reasoned_gone_asset_test",
        size = "small",
        gone = True,
        not_in_reason = ["did not state"],
        reason = ["deleted by the rule"],
        target_under_test = ":reasoned_gone_asset",
    )
    for states, test in [
        ("gone_with_inputs", _asset_gone_with_inputs_test),
        ("gone_not_bool", _asset_gone_not_bool_test),
    ]:
        _stated_asset(
            name = "asset_" + states,
            states = states,
            tags = ["manual"],
        )
        test(
            name = "asset_%s_test" % states,
            size = "small",
            target_under_test = ":asset_" + states,
        )

    # The same for what a rule states in `DartLinkInputsInfo`.
    for states, test in [
        ("gone_with_inputs", _stated_gone_with_inputs_test),
        ("neither", _stated_neither_test),
        ("gone_not_bool", _stated_gone_not_bool_test),
    ]:
        _copied_library(
            name = "statement_" + states,
            asset = ":ca_linked_shared",
            states = states,
            tags = ["manual"],
        )
        test(
            name = "stated_%s_test" % states,
            size = "small",
            target_under_test = ":statement_" + states,
        )
