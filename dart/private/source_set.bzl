"""`dart_source_set` and the shared source-assembly helper.

The Dart toolchain resolves a `part` directive by filesystem adjacency to its
library, and a package's `package:` imports against a single `rootUri`. So a
package whose files are split between the source tree and `bazel-out` (because a
`dart_codegen` writes generated members) must be reassembled into one real
directory before `dart compile`/`dart` will resolve it.

`assemble_source_dir` does that with bazel-lib's `copy_to_directory` (portable on
Windows, no bash, no symlink privilege). The consuming `dart_binary`/`dart_test`
assemble each package's complete file set at build time via `colocate_packages`
and `colocate_entrypoint` — the consumer is the only place that sees a package's
files across all of its `dart_library` fragments. `dart_source_set` exposes the
same assembly as a standalone, package-agnostic primitive (consumed via
`dart_library`'s `srcs_dir`).
"""

load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory_bin_action")
load("//dart/private:dart_info.bzl", "derived_package_info", "package_lib_prefix")

COPY_TO_DIRECTORY_TOOLCHAINS = ["@bazel_lib//lib:copy_to_directory_toolchain_type"]

def needs_source_assembly(srcs):
    """Whether `srcs` must be assembled into one directory before compilation.

    A pure source-tree package already lives in one directory; the moment any
    member is generated (in `bazel-out`), the package's files straddle two real
    directories and must be co-located.

    Args:
      srcs: A list of File objects (a rule's own `ctx.files.srcs`).

    Returns:
      True iff at least one File is not a source-tree file.
    """
    for f in srcs:
        if not f.is_source:
            return True
    return False

def assemble_source_dir(ctx, name, srcs, root_paths = ["."], replace_prefixes = {}, include_external_repositories = []):
    """Assembles `srcs` into one tree-artifact directory and returns it.

    Source and generated files are copied into a single declared directory at
    their package-relative paths (default `root_paths = ["."]` strips the owning
    Bazel package prefix, yielding the `lib/...` layout the Dart `rootUri`
    expects).

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      name: Basename for the declared directory (unique within the package).
      srcs: List of File objects (source and/or generated) to assemble.
      root_paths: `copy_to_directory` root paths; `"."` is the current package.
      replace_prefixes: `copy_to_directory` prefix rewrites for cross-package layout.
      include_external_repositories: `copy_to_directory` external repo name
        patterns; external files are excluded unless their repo matches, and
        matching files are staged at their repo-relative paths.

    Returns:
      The assembled directory File (a tree artifact).
    """
    dst = ctx.actions.declare_directory(name)
    copy_to_directory_bin_action(
        ctx,
        name = name,
        dst = dst,
        copy_to_directory_bin = ctx.toolchains["@bazel_lib//lib:copy_to_directory_toolchain_type"].copy_to_directory_info.bin,
        files = srcs,
        root_paths = root_paths,
        replace_prefixes = replace_prefixes,
        include_external_repositories = include_external_repositories,
    )
    return dst

def package_for(short_path, packages):
    """Returns the package_name owning `short_path`, by longest matching `lib_root`.

    A package owns its `<lib_root>/lib/` subtree and nothing else in the
    directory: `lib/` is what a `package:` URI can reach, and staging strips
    `lib_root`, so a `test/` or `tool/` file co-located into the package would
    land somewhere no import resolves — and a generated entrypoint would lose
    the relative imports that resolved from its real location. The rule is the
    same wherever the package sits. Among several matches the longest `lib_root`
    wins; the root package's is empty, so it is taken only when nothing else
    matched at all.

    The one path that is not under `lib/` is `lib_root` itself, which matches
    exactly. That is a package whose files arrive as one opaque directory — a
    `dart_library(srcs_dir = ...)`, or a record `colocate_packages` already
    rewrote to its `.pkgsrcs` directory — where the directory *is* the package
    root and `lib/` sits inside it.

    Args:
      short_path: A File's `short_path`.
      packages: List of `DartPackageInfo` (read for `package_name` and `lib_root`).

    Returns:
      The matching `package_name`, or `None` if no package owns the path.
    """
    best_name = None
    best_len = -1
    for p in packages:
        lr = p.lib_root
        prefix = package_lib_prefix(lr)

        # `<lib_root>/lib` — the library directory itself, not a file under it.
        lib_dir = prefix[:-1]
        under_lib = short_path == lib_dir or short_path.startswith(prefix)
        if not lr:
            # Root package: owns `lib/...` files. Lowest precedence.
            if under_lib and best_len < 0:
                best_name = p.package_name
                best_len = 0
        elif under_lib or short_path == lr:
            if len(lr) > best_len:
                best_name = p.package_name
                best_len = len(lr)
    return best_name

def colocate_packages(ctx, packages, all_srcs):
    """Co-locates each package's split source/generated files into one directory.

    Groups `all_srcs` by the package whose `lib/` they belong to (longest
    `lib_root` match — see `package_for`).
    Any package with at least one generated file (and not already a single
    pre-assembled directory) is assembled into one tree-artifact directory, so it
    has a single real `rootUri` at compile time. This is what makes a package
    whose files are split across the source tree and `bazel-out` (codegen) and/or
    across several `dart_library` targets resolve — the consumer is the only place
    that sees the package's complete file set.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of `DartPackageInfo` (from `collect_packages`).
      all_srcs: Flat list of transitive source Files.

    Returns:
      `(packages2, srcs2)` — packages with each assembled package's `lib_root`
      rewritten to its assembled directory, and the matching File list (assembled
      directories plus untouched files) to feed the compile action.
    """
    by_pkg = {}
    loose = []
    for f in all_srcs:
        name = package_for(f.short_path, packages)
        if name == None:
            loose.append(f)
        elif name in by_pkg:
            by_pkg[name].append(f)
        else:
            by_pkg[name] = [f]

    # Files matching no package (pub/transitive sources that only ride along in
    # transitive_srcs) are already co-located in their own source location; pass
    # them through unchanged as compile inputs.
    packages2 = []
    srcs2 = list(loose)
    for p in packages:
        files = by_pkg.get(p.package_name, [])
        already_dir = len(files) == 1 and files[0].is_directory
        if needs_source_assembly(files) and not already_dir:
            mangled = p.package_name
            for ch in ["/", ":", ".", "+"]:
                mangled = mangled.replace(ch, "_")
            assembled = assemble_source_dir(
                ctx,
                ctx.label.name + "." + mangled + ".pkgsrcs",
                files,
                root_paths = [p.lib_root] if p.lib_root else ["."],
            )

            # Only `lib_root` changes. Everything else the record carries —
            # its language version, the code assets the package owns — is as
            # true of the assembled copy as of the original, and is carried
            # through rather than re-listed here.
            packages2.append(derived_package_info(p, lib_root = assembled.short_path))
            srcs2.append(assembled)
        else:
            packages2.append(p)
            for f in files:
                srcs2.append(f)
    return packages2, srcs2

def colocate_entrypoint(ctx, main, own_srcs):
    """Co-locates an entrypoint `main` with its own generated sibling sources.

    A `dart_binary`/`dart_test` whose own `srcs` include a generated file that is
    a `part`/relative-import sibling of `main` (e.g. a mockito `.mocks.dart`
    generated for the test file itself) needs `main` and those files in one real
    directory. When that's the case, assemble them and compile `main` from inside
    the assembled directory.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      main: The entrypoint `.dart` File.
      own_srcs: The rule's own `srcs` Files (not those from `deps`).

    Returns:
      `(main_input, main_arg, extra_inputs)` — `main_input` is the File to add to
      action inputs (the assembled directory when assembled, else `main`);
      `main_arg` is the entrypoint's logical path in the CFE filesystem;
      `extra_inputs` are `own_srcs` to add as inputs when not assembled (empty
      when assembled).
    """
    if not needs_source_assembly(own_srcs):
        return main, main.path, own_srcs

    # Preserve repository-relative paths so mounting the tree does not change
    # the entrypoint's logical URI or the base of its relative imports.
    assembled = assemble_source_dir(
        ctx,
        ctx.label.name + ".main.entrysrcs",
        [main] + own_srcs,
        root_paths = [],
    )
    return assembled, main.short_path, []

def _dart_source_set_impl(ctx):
    dst = assemble_source_dir(
        ctx,
        name = ctx.label.name,
        srcs = ctx.files.srcs,
        root_paths = ctx.attr.root_paths,
        replace_prefixes = ctx.attr.replace_prefixes,
    )
    return [DefaultInfo(
        files = depset([dst]),
        runfiles = ctx.runfiles(files = [dst]),
    )]

dart_source_set = rule(
    implementation = _dart_source_set_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart files (source and/or generated, from any target) to assemble into one directory.",
            allow_files = True,
            mandatory = True,
        ),
        "root_paths": attr.string_list(
            doc = "Paths treated as roots in the output directory (stripped). `\".\"` is this target's Bazel package. Set additional roots to flatten files from other packages.",
            default = ["."],
        ),
        "replace_prefixes": attr.string_dict(
            doc = "Map of output-path prefixes to rewrite, applied after `root_paths` stripping. Use to place cross-package inputs under `lib/`.",
        ),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Assembles Dart sources (hand-written + generated) into one tree-artifact directory. Package-agnostic; consume via `dart_library`'s `srcs_dir`.",
)
