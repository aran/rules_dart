"""The `dart_code_asset` rule.

Binds a native dynamic library — a `cc_shared_library`, or a prebuilt
`.so`/`.dylib`/`.dll` file — to the Dart code-asset id that the owning package's `@Native`/`@ffi.DefaultAsset` bindings
use. This is the seam between Bazel's native build and Dart's code-asset
resolution: `dart_test` / `dart_binary` consume `DartCodeAssetInfo` via their
`code_assets` attribute and synthesise the `native_assets.yaml` that
`frontend_server --native-assets` embeds into the kernel.

Two-tier usage: a native-asset-owning package can ship a target exposing
`DartCodeAssetInfo` itself; otherwise rules_dart provides one under
`//dart/ext/<package>` (see `//dart/ext/sqlite3`).

`DartCodeAssetInfo` carries what upstream's `CodeAsset` carries — id, link
mode, and the library — and what only the build knows: what the library was
linked from and its dSYM, from the action that wrote it, or from
`DartLinkInputsInfo` and `DartDsymInfo` when `file` states them. Bundling
concerns (where the file lands inside an application,
what it is renamed to) belong to the consumer; rules_flutter layers those on
top of this provider rather than rules_dart guessing at them.
"""

load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartCodeAssetInfo", "DartDsymInfo", "DartLinkInputsInfo")
load("//dart/private:runtime.bzl", "non_dart_transition")

visibility("//dart/...")

_APPLE_OSES = ["ios", "macos", "tvos", "visionos", "watchos"]

# What the C++ rules call the action that links: `cc_common.link` on every
# platform, `ObjcLink` when it links an Objective-C executable, as Apple binary
# rules do, dynamic libraries included. Any other action writing a library, a
# copy above all, has inputs that say nothing about what is in it.
#
# `Rustc` is not one, though rules_rust's `rust_shared_library` writes its
# library with it. On macOS rustc compiles the crate to an object file inside
# that action, links it, runs dsymutil and deletes the object. The library's
# debug map names that object and no input of the action provides it, so a
# dsymutil run on the library given every input still gets no line tables for
# the crate's own code (its Rust and C dependencies keep theirs).
_LINK_MNEMONICS = ["CppLink", "ObjcLink"]

_RUSTC_UNKNOWN = ("wrote it with a `Rustc` action, which links the crate from an object file it makes " +
                  "and deletes inside that action, so no input of the action is what the library was linked from")
_RUSTC_ADVICE = "Have `file` return DartLinkInputsInfo from a rule that holds the crate's object file."

_LibraryActionsInfo = provider(
    doc = """The actions of the target behind a `dart_code_asset`'s `file`, and \
what the targets behind it state and provide, when it is a `filegroup`.""",
    fields = {
        "actions": "list[Action]: The target's actions; behind a `filegroup`, those of the targets it wraps.",
        "stated": "list[tuple[Label, DartLinkInputsInfo]]: What the targets wrapped by a `filegroup` state, with their labels. Empty for any other rule, whose own statement `dart_code_asset` reads from the target itself.",
        "stated_dsyms": "list[tuple[Label, DartDsymInfo]]: The dSYMs the targets wrapped by a `filegroup` state, as `stated` holds what they state of links.",
        "shared_libraries": "list[tuple[Label, CcSharedLibraryInfo, depset[File]]]: The targets with a `CcSharedLibraryInfo` wrapped by a `filegroup`, with their labels and every file each provides of its own: its files, its output groups and the files of its libraries. Empty for any other rule, which `dart_code_asset` reads `CcSharedLibraryInfo` from itself.",
    },
)

def _own_files(target):
    """Every file a target with a `CcSharedLibraryInfo` provides of its own."""
    files = [target[DefaultInfo].files]
    if OutputGroupInfo in target:
        for group in dir(target[OutputGroupInfo]):
            files_of_group = getattr(target[OutputGroupInfo], group, None)
            if type(files_of_group) == "depset":
                files.append(files_of_group)
    libraries = []
    for lib in target[CcSharedLibraryInfo].linker_input.libraries:
        for file in [lib.dynamic_library, lib.resolved_symlink_dynamic_library, lib.interface_library, lib.resolved_symlink_interface_library]:
            if file != None:
                libraries.append(file)
    return depset(libraries, transitive = files)

def _library_actions_aspect_impl(target, ctx):
    if ctx.rule.kind != "filegroup":
        return [_LibraryActionsInfo(actions = target.actions, stated = [], stated_dsyms = [], shared_libraries = [])]

    # A `filegroup` adds nothing to the files it names, so the link of a
    # library behind it is the link of the library: what the targets it wraps
    # own and say. Nothing else forwards.
    actions = []
    stated = []
    stated_dsyms = []
    shared_libraries = []
    for src in ctx.rule.attr.srcs:
        if DartLinkInputsInfo in src:
            stated.append((src.label, src[DartLinkInputsInfo]))
        if DartDsymInfo in src:
            stated_dsyms.append((src.label, src[DartDsymInfo]))
        if CcSharedLibraryInfo in src:
            shared_libraries.append((src.label, src[CcSharedLibraryInfo], _own_files(src)))
        if _LibraryActionsInfo in src:
            actions.extend(src[_LibraryActionsInfo].actions)
            stated.extend(src[_LibraryActionsInfo].stated)
            stated_dsyms.extend(src[_LibraryActionsInfo].stated_dsyms)
            shared_libraries.extend(src[_LibraryActionsInfo].shared_libraries)
    return [_LibraryActionsInfo(actions = actions, stated = stated, stated_dsyms = stated_dsyms, shared_libraries = shared_libraries)]

# Reads the link from the action itself: it alone says what a
# `cc_shared_library` linked in, which is less than its `deps` reach when
# `dynamic_deps` supply part of them, and it serves any rule that links.
# Reaches through `srcs` so that a `filegroup` can be seen through; the
# implementation takes only a `filegroup`'s, and the rules that have `srcs` of
# their own (a `cc_binary`'s sources, say) get no more than their own actions.
_library_actions_aspect = aspect(
    implementation = _library_actions_aspect_impl,
    attr_aspects = ["srcs"],
    apply_to_generating_rules = True,
    doc = "Exposes the actions of the target a `dart_code_asset` binds, and of the targets a `filegroup` there wraps.",
)

def _library_extension(ctx):
    """The file extension of a dynamic library on the target platform."""
    if ctx.target_platform_has_constraint(ctx.attr._windows[platform_common.ConstraintValueInfo]):
        return "windows", ".dll"
    for os in _APPLE_OSES:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, "_" + os)[platform_common.ConstraintValueInfo]):
            return os, ".dylib"
    return None, ".so"

def _writing_action(library_target, output):
    """The action in `library_target` writing `output`, or None."""
    if _LibraryActionsInfo in library_target:
        for action in library_target[_LibraryActionsInfo].actions:
            if output in action.outputs.to_list():
                return action
    return None

def _stated_link_inputs(ctx, library_target, library):
    """What `library_target` says `library` was linked from, or None.

    The target's own statement must be about `library`. Behind a `filegroup`
    the targets it wraps may state other libraries, which are not the concern
    of this one; two of them stating `library` must agree.
    """
    if DartLinkInputsInfo in library_target:
        stated = library_target[DartLinkInputsInfo]
        if stated.library != library:
            fail(("dart_code_asset %s: DartLinkInputsInfo of %s describes %s, " +
                  "but `file` provides %s.") %
                 (ctx.label, library_target.label, stated.library.short_path, library.short_path))
        return stated.inputs
    if _LibraryActionsInfo not in library_target:
        return None

    statements = {}
    for label, stated in library_target[_LibraryActionsInfo].stated:
        if stated.library == library:
            statements[label] = stated.inputs
    if not statements:
        return None
    labels = sorted(statements)
    first = statements[labels[0]]
    for label in labels[1:]:
        # Each is one target's statement, reached by however many paths.
        if statements[label] != first and _paths(statements[label]) != _paths(first):
            fail(("dart_code_asset %s: %s and %s both state what %s was linked from, " +
                  "and they disagree. Only the target that linked it should.") %
                 (ctx.label, labels[0], label, library.short_path))
    return first

def _paths(inputs):
    return sorted([file.path for file in inputs.to_list()])

def _stated_dsym(ctx, library_target, library):
    """The dSYM `library_target` says is `library`'s, or None.

    As `_stated_link_inputs` reads statements of what a library was linked from.
    """
    if DartDsymInfo in library_target:
        stated = library_target[DartDsymInfo]
        if stated.library != library:
            fail(("dart_code_asset %s: DartDsymInfo of %s describes %s, " +
                  "but `file` provides %s.") %
                 (ctx.label, library_target.label, stated.library.short_path, library.short_path))
        return stated.dsym
    if _LibraryActionsInfo not in library_target:
        return None

    statements = {}
    for label, stated in library_target[_LibraryActionsInfo].stated_dsyms:
        if stated.library == library:
            statements[label] = stated.dsym
    if not statements:
        return None
    labels = sorted(statements)
    first = statements[labels[0]]
    for label in labels[1:]:
        if statements[label] != first:
            fail(("dart_code_asset %s: %s and %s both state the dSYM of %s, " +
                  "and they disagree. Only one target should.") %
                 (ctx.label, labels[0], label, library.short_path))
    return first

def _dsym_of(ctx, library_target, library, written):
    """The dSYM of `library`, written as `written`, or None.

    What `library_target` states in `DartDsymInfo`; failing that, the
    `<name>.dSYM` directory written by the action that wrote the library. That
    the one action wrote both is what makes it this library's dSYM, whatever
    the rule behind it (rustc's and a C++ link's alike) and whatever output
    group it is offered in: a dSYM merely forwarded beside a library may
    describe another one.
    """
    stated = _stated_dsym(ctx, library_target, library)
    if stated != None:
        return stated
    action = _writing_action(library_target, written)
    if action == None:
        return None
    name = written.basename + ".dSYM"
    for output in action.outputs.to_list():
        if output.is_directory and output.basename == name:
            return output
    return None

def _wrapped_shared_library(ctx, library_target):
    """The one `cc_shared_library` behind a `filegroup`, as a tuple of its `CcSharedLibraryInfo` and the files it provides, or None."""
    if _LibraryActionsInfo not in library_target:
        return None
    wrapped = {}
    for label, info, own_files in library_target[_LibraryActionsInfo].shared_libraries:
        wrapped[label] = (info, own_files)
    if len(wrapped) > 1:
        fail(("dart_code_asset %s: `file` %s wraps %d shared libraries, %s, " +
              "and binds one. Name the one to bind.") %
             (ctx.label, library_target.label, len(wrapped), ", ".join([str(label) for label in sorted(wrapped)])))
    return wrapped.values()[0] if wrapped else None

def _dynamic_library(ctx, library_target, info):
    """The `LibraryToLink` of `info` that has a dynamic library."""
    libraries = info.linker_input.libraries
    if not libraries:
        fail("dart_code_asset %s: `file` %s has no libraries in its CcSharedLibraryInfo." %
             (ctx.label, library_target.label))
    for lib in libraries:
        if lib.dynamic_library != None:
            return lib
    fail("dart_code_asset %s: `file` %s has no dynamic_library File on its CcSharedLibraryInfo." %
         (ctx.label, library_target.label))

def _filegroup_provides_library(filegroup, lib, own_files):
    """Whether a `filegroup` provides `lib` and no file but its target's own.

    What a `filegroup` provides is what it was asked to: all the files of its
    `srcs`, or those of one output group. It stands for the library only when
    that is the library, with nothing else but what the library's target
    itself provides (a Windows import library, a `.pdb`).
    """
    provided = filegroup[DefaultInfo].files.to_list()
    own = {file: True for file in own_files.to_list()}
    for file in provided:
        if file not in own:
            return False
    return lib.dynamic_library in provided or lib.resolved_symlink_dynamic_library in provided

def _linked_from(ctx, library_target, library, written):
    """What `library`, written as `written`, was linked from.

    From what `library_target` states in `DartLinkInputsInfo`; failing that,
    the inputs of the action writing `written` if that links. A source file
    was linked from nothing Bazel knows.

    Returns:
      A tuple of the depset of its link's inputs, and why those are unknown.
      The inputs are `None` and the reason is set when the link is out of
      sight: a rule that is no `filegroup` forwards a library another target
      wrote, or an action that does not link wrote it, as a copy's does.
    """
    inputs = _stated_link_inputs(ctx, library_target, library)
    if inputs != None:
        return inputs, None
    action = _writing_action(library_target, written)
    if action != None and action.mnemonic in _LINK_MNEMONICS:
        return action.inputs, None
    if action == None and written.is_source:
        return depset(), None
    advice = "Name the target that linked it, or have `file` return DartLinkInputsInfo."
    if action != None and action.mnemonic == "Rustc":
        seen = _RUSTC_UNKNOWN
        advice = _RUSTC_ADVICE
    elif action != None:
        seen = "wrote it with a `%s` action, which does not link" % action.mnemonic
    else:
        seen = "did not write it"
    return None, ("dart_code_asset %s: what %s was linked from is unknown: `file` %s %s. %s") % (
        ctx.label,
        library.short_path,
        library_target.label,
        seen,
        advice,
    )

def _bound_library(ctx, library_target, library, written):
    """What the build knows of `library`, written as `written`.

    Returns:
      A tuple of `library`, the depset of its link's inputs, why those are
      unknown, and its dSYM.
    """
    inputs, reason = _linked_from(ctx, library_target, library, written)
    dsym = _dsym_of(ctx, library_target, library, written)
    if reason != None and dsym != None:
        reason += " For debug symbols, use `dsym`, the library's dSYM, instead of running dsymutil."
    return library, inputs, reason, dsym

def _extract_dynamic_library(ctx, library_target):
    """The dynamic-library File behind `file`, and what the build knows of it.

    From a `cc_shared_library`, or a `filegroup` wrapping exactly one and
    providing its library and nothing but its own files, read from
    `CcSharedLibraryInfo.linker_input.libraries[*].dynamic_library` rather than
    `DefaultInfo.files`, which on Windows may also hold the import library and
    `.pdb`. Otherwise the target must be one library file, named as the target
    platform names one.

    What it was linked from is what the target states in `DartLinkInputsInfo`;
    failing that, the inputs of the target's action linking it. A `filegroup`
    is looked through, to the targets it wraps and what they state. A source
    file was linked from nothing Bazel knows.

    Returns:
      A tuple of the library `File`, the depset of its link's inputs, why those
      are unknown, and its dSYM or `None`. The inputs are `None` and the reason
      is set when the link is out of sight: a rule that is no `filegroup`
      forwards a library another target wrote, as a platform transition does,
      or an action that does not link wrote it, as a copy does.
    """
    lib = None
    if CcSharedLibraryInfo in library_target:
        lib = _dynamic_library(ctx, library_target, library_target[CcSharedLibraryInfo])
    else:
        wrapped = _wrapped_shared_library(ctx, library_target)
        if wrapped != None:
            candidate = _dynamic_library(ctx, library_target, wrapped[0])
            if _filegroup_provides_library(library_target, candidate, wrapped[1]):
                lib = candidate
    if lib != None:
        # `dynamic_library` may be a symlink to what the link wrote.
        return _bound_library(ctx, library_target, lib.dynamic_library, lib.resolved_symlink_dynamic_library or lib.dynamic_library)

    files = library_target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail(("dart_code_asset %s: `file` %s is neither a `cc_shared_library` " +
              "nor a single prebuilt library file; it has %d files: %s.") %
             (ctx.label, library_target.label, len(files), ", ".join([f.short_path for f in files])))
    library = files[0]
    os, extension = _library_extension(ctx)
    name = library.basename
    if not (name.endswith(extension) or (extension == ".so" and ".so." in name)):
        fail(("dart_code_asset %s: `file` file %s is not a dynamic library " +
              "for the target platform, which loads %s files%s.") %
             (ctx.label, library.short_path, extension, " (%s)" % os if os else ""))
    return _bound_library(ctx, library_target, library, library)

def _dart_code_asset_impl(ctx):
    link_mode = ctx.attr.link_mode

    if link_mode == "static":
        fail(("dart_code_asset %s: link_mode = \"static\" is reserved by the " +
              "Dart SDK but implemented by neither the Dart VM nor the " +
              "Flutter engine. Track upstream support at " +
              "https://github.com/dart-lang/sdk/issues/49418. Use " +
              "`dynamic_loading_bundle` until that lands.") % ctx.label)

    if link_mode not in CODE_ASSET_LINK_MODES:
        fail("dart_code_asset %s: invalid link_mode %r. Expected one of: %s." %
             (ctx.label, link_mode, ", ".join(CODE_ASSET_LINK_MODES)))

    file = None
    uri = ""
    link_inputs = depset()
    unset_reason = None
    dsym = None

    if link_mode == "dynamic_loading_bundle":
        if ctx.attr.file == None:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_bundle\" " +
                  "requires `file`, a `cc_shared_library` or a prebuilt library file.") % ctx.label)
        if ctx.attr.uri:
            fail(("dart_code_asset %s: `uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)
        file, link_inputs, unset_reason, dsym = _extract_dynamic_library(ctx, ctx.attr.file)
    elif link_mode == "dynamic_loading_system":
        if not ctx.attr.uri:
            fail(("dart_code_asset %s: link_mode = \"dynamic_loading_system\" " +
                  "requires `uri = \"<uri>\"`.") % ctx.label)
        if ctx.attr.file != None:
            fail(("dart_code_asset %s: `file` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        uri = ctx.attr.uri
    else:  # dynamic_loading_executable / dynamic_loading_process
        if ctx.attr.file != None:
            fail(("dart_code_asset %s: `file` is only valid with " +
                  "link_mode = \"dynamic_loading_bundle\".") % ctx.label)
        if ctx.attr.uri:
            fail(("dart_code_asset %s: `uri` is only valid with " +
                  "link_mode = \"dynamic_loading_system\".") % ctx.label)

    files = depset([file] if file != None else [])

    return [
        DefaultInfo(files = files),
        DartCodeAssetInfo(
            asset_id = ctx.attr.asset_id,
            link_mode = link_mode,
            file = file,
            uri = uri,
            link_inputs = link_inputs,
            link_inputs_unset_reason = unset_reason,
            dsym = dsym,
        ),
    ]

dart_code_asset = rule(
    implementation = _dart_code_asset_impl,
    # Its outputs are the same under every web compiler, whether or not
    # creation locations are tracked and whatever environment the executable
    # above it compiles in: built once, with none of them.
    cfg = non_dart_transition,
    attrs = {
        "asset_id": attr.string(
            mandatory = True,
            doc = "The code-asset id the owning package's `@Native`/`@ffi.DefaultAsset` declares (e.g. `package:sqlite3/src/ffi/libsqlite3.g.dart`).",
        ),
        "link_mode": attr.string(
            default = "dynamic_loading_bundle",
            doc = """How the runtime loads this asset. One of `dynamic_loading_bundle` (a \
Bazel-built library shipped alongside the app), `dynamic_loading_system` (a library already \
present on the target system, named by `uri`), `dynamic_loading_executable`, or \
`dynamic_loading_process`. The reserved `static` mode fails fast — neither the Dart VM nor the \
Flutter engine implements it.

May be a `select()`: an ext package that bundles on one platform and uses the system library on \
another expresses that here, and consumers see a single target.""",
            values = list(CODE_ASSET_LINK_MODES) + ["static"],
        ),
        "file": attr.label(
            allow_files = True,
            aspects = [_library_actions_aspect],
            doc = """The dynamic library that backs this code asset: a `cc_shared_library`, or one \
prebuilt library file (a checked-in or downloaded `.so`, `.dylib` or `.dll`, as \
`cc_import.shared_library` takes it), whose extension must be the target platform's. A target \
that provides `DartLinkInputsInfo` for the library says what it was linked from, and one that \
provides `DartDsymInfo` says what its dSYM is; otherwise those are known only from the target that \
wrote it, which may be behind a `filegroup`, nested ones included. \
A `filegroup` stands for the `cc_shared_library` it wraps only when it provides that library and \
nothing but the files that target provides itself; with other files, or an `output_group` without the \
library, `file` must be one library file. Required for `dynamic_loading_bundle`; forbidden for the other link modes.""",
        ),
        "_windows": attr.label(default = "@platforms//os:windows"),
        "_ios": attr.label(default = "@platforms//os:ios"),
        "_macos": attr.label(default = "@platforms//os:macos"),
        "_tvos": attr.label(default = "@platforms//os:tvos"),
        "_visionos": attr.label(default = "@platforms//os:visionos"),
        "_watchos": attr.label(default = "@platforms//os:watchos"),
        "uri": attr.string(
            doc = "System library URI, e.g. `libsqlite3.so.0`. Required for `dynamic_loading_system`; forbidden for the other link modes.",
        ),
    },
    provides = [DartCodeAssetInfo],
    doc = "Binds a native dynamic library, built by Bazel or prebuilt, to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.",
)
