"""`dart_source_set`, the shared source-assembly helper, and executable inputs.

A package whose files are split between the source tree and `bazel-out` (because
a `dart_codegen` writes generated members, or several `dart_library` targets
contribute to one package) keeps its one `lib_root`. Compiles name every package
as `org-dartlang-bazel:///<lib_root>`, and the compiler resolves that through a
multi-root file system: the source tree and the bin directory both serve the
`<lib_root>/...` paths, and each file is found where it sits (`gen_kernel_args`
in `common.bzl`). So `dart_binary` and `dart_test` compile in place and copy
nothing: `executable_inputs` gathers what they read. `merge_package_records`
leaves one record per package name, so a name never maps to two roots.

Copies remain where a consumer needs one real directory tree:

- `assemble_source_dir`, which `dart_source_set` and `project_staging.bzl` use.
  It copies with the `copy_tree` tool (`dart/private/tools/copy_tree.dart`),
  reached through `//dart:copy_toolchain_type`. The tool is portable to Windows,
  needs no bash and no symlink privilege. `dart_source_set` exposes it as a
  package-agnostic primitive, consumed via `dart_library`'s `srcs_dir`.
- `colocate_packages` and `colocate_entrypoint`, the directory-assembly helpers
  `dart/utils.bzl` exports to rule sets built on rules_dart. No rule in this
  repository calls them.
"""

load("//dart/private:dart_info.bzl", "derived_package_info")

_COPY_TOOLCHAIN_TYPE = Label("//dart:copy_toolchain_type")

# The toolchain that provides the `copy_tree` tool. Rules that copy files list it
# here; `dart/utils.bzl` exports the same list for rule sets built on rules_dart.
COPY_TO_DIRECTORY_TOOLCHAINS = [_COPY_TOOLCHAIN_TYPE]

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
      srcs: List of File objects (source and/or generated, or tree artifacts)
        to assemble.
      root_paths: Root paths to strip; `"."` is the current package. Globs are
        supported.
      replace_prefixes: Prefix rewrites, applied after the roots, for cross-package
        layout. Globs are supported.
      include_external_repositories: Repository name patterns. Files from another
        repository are excluded unless their repository matches, and matching
        files are staged at their repo-relative paths.

    Returns:
      The assembled directory File (a tree artifact).
    """
    dst = ctx.actions.declare_directory(name)

    # `"."` names the calling rule's package. A replace key ending in `**` would
    # match every path, so it is rejected.
    roots = [p if p != "." else ctx.label.package for p in root_paths]
    for prefix in replace_prefixes.keys():
        if prefix.endswith("**"):
            fail("replace_prefix '{}' must not end with '**' glob expression".format(prefix))

    # The options and the file list go in a params file, one value per line, so a
    # long list stays off the command line. `copy_tree` reads its records in order.
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add(dst.path)
    for root in roots:
        args.add("--root")
        args.add(root)
    for prefix, value in replace_prefixes.items():
        args.add("--replace")
        args.add(prefix)
        args.add(value)
    for pattern in include_external_repositories:
        args.add("--external")
        args.add(pattern)
    args.add("--workspace")
    args.add(ctx.label.workspace_name)
    args.add_all(srcs, map_each = _copy_record, expand_directories = True)

    copy_tc = ctx.toolchains[_COPY_TOOLCHAIN_TYPE]
    ctx.actions.run(
        executable = copy_tc.dart,
        arguments = [copy_tc.copy_tree.path, args],
        inputs = depset(direct = [copy_tc.copy_tree] + srcs, transitive = [copy_tc.runtime_files]),
        outputs = [dst],
        mnemonic = "DartCopyTree",
        progress_message = "Copying files to directory %{output}",
        toolchain = _COPY_TOOLCHAIN_TYPE,
    )
    return dst

def _copy_record(f):
    """The `--file` record `copy_tree` reads for one input file.

    `workspace_path` is the file's path inside its repository: `short_path`
    without the `../<repo>/` prefix an external file carries.

    Args:
      f: A File from `srcs`, or a file of a tree artifact in `srcs`.

    Returns:
      The record's values, which Args flattens into the params file.
    """
    short = f.short_path
    workspace_path = short[short.find("/", 3) + 1:] if short.startswith("../") else short
    return ["--file", f.path, short, f.owner.workspace_name, workspace_path]

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

    Callers matching many files against one package list build the index once
    with `package_index` and call `package_for_index` instead: this wrapper
    rebuilds it on every call.

    Args:
      short_path: A File's `short_path`.
      packages: List of `DartPackageInfo` (read for `package_name` and `lib_root`).

    Returns:
      The matching `package_name`, or `None` if no package owns the path.
    """
    return package_for_index(short_path, package_index(packages))

def package_index(packages):
    """Indexes packages by `lib_root`, for `package_for_index`.

    Where several records share a `lib_root`, the first keeps it, as
    `package_for`'s scan in list order always decided.

    Args:
      packages: List of `DartPackageInfo` (read for `package_name` and `lib_root`).

    Returns:
      Dict of `lib_root` to `package_name`.
    """
    index = {}
    for p in packages:
        if p.lib_root not in index:
            index[p.lib_root] = p.package_name
    return index

def package_for_index(short_path, index):
    """`package_for` against an index from `package_index`.

    The only `lib_root`s that can own a path are the path itself (an opaque
    package directory) and each prefix that ends just before a `lib` component
    of it. Trying those longest first, and taking the first that names a
    package, is `package_for`'s longest-match rule in time proportional to the
    path's depth rather than to the number of packages: an executable matches
    every file of its closure, so the scan cost files × packages per target.

    Args:
      short_path: A File's `short_path`.
      index: Dict of `lib_root` to `package_name`, from `package_index`.

    Returns:
      The matching `package_name`, or `None` if no package owns the path.
    """

    # The path itself is longer than any prefix of it. The root package's
    # empty `lib_root` owns only its `lib/`, never a path by equality.
    name = index.get(short_path) if short_path else None
    if name != None:
        return name
    parts = short_path.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "lib":
            name = index.get("/".join(parts[:i]))
            if name != None:
                return name
    return None

def colocate_packages(ctx, packages, all_srcs, members = {}):
    """Assembles each package's split source/generated files into one directory.

    For a caller that needs every package to have one real `rootUri`. Groups
    `all_srcs` by the package whose `lib/` they belong to (longest `lib_root`
    match — see `package_for`). Any package with at least one generated file (and
    not already a single pre-assembled directory) is assembled into one
    tree-artifact directory. rules_dart's own executables do not call this: their
    multi-root compile resolves such a package in place (see `executable_inputs`).

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of `DartPackageInfo` (from `collect_packages`).
      all_srcs: Flat list of transitive source Files.
      members: Dict of package name to Files that belong to that package
        outside its `lib/` — an executable's own sources, when it states the
        package. They are assembled with the package's `lib/` so they sit
        inside its root, where its `languageVersion` applies.

    Returns:
      `(packages2, srcs2)` — packages with each assembled package's `lib_root`
      rewritten to its assembled directory, and the matching File list (assembled
      directories plus untouched files) to feed the compile action.
    """
    by_pkg = {}
    loose = []
    index = package_index(packages)
    for f in all_srcs:
        name = package_for_index(f.short_path, index)
        if name == None:
            loose.append(f)
        elif name in by_pkg:
            by_pkg[name].append(f)
        else:
            by_pkg[name] = [f]
    for name, files in members.items():
        by_pkg[name] = by_pkg.get(name, []) + files

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
    """Assembles an entrypoint `main` with its own generated sibling sources.

    For a caller that needs `main` and its siblings in one real directory. Not
    used by rules_dart's executables: a generated sibling such as a mockito
    `.mocks.dart` resolves beside `main` through the multi-root compile (see
    `executable_inputs`).

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      main: The entrypoint `.dart` File.
      own_srcs: The rule's own `srcs` Files (not those from `deps`).

    Returns:
      `(main_input, main_arg, extra_inputs)` — `main_input` is the File to add to
      action inputs (the assembled directory when assembled, else `main`);
      `main_arg` is the path string to pass as the compile target; `extra_inputs`
      are `own_srcs` to add as inputs when not assembled (empty when assembled).
    """
    if not needs_source_assembly(own_srcs):
        return main, main.path, own_srcs

    # `.entrysrcs` (vs packages' `.pkgsrcs`) so this dir can't collide with a package dir.
    assembled = assemble_source_dir(ctx, ctx.label.name + ".main.entrysrcs", [main] + own_srcs)
    rel = main.short_path
    if ctx.label.package and rel.startswith(ctx.label.package + "/"):
        rel = rel[len(ctx.label.package) + 1:]
    return assembled, assembled.path + "/" + rel, []

def executable_inputs(packages, dep_srcs, main, own_srcs, own_package = None):
    """Gathers what an executable's compile reads. Nothing is copied.

    Every package keeps its `lib_root`, whether its files sit in the source tree,
    in `bazel-out`, or both: the compile names it `org-dartlang-bazel:///<lib_root>`
    and the multi-root file system finds each file where it is (see the module
    docstring). The entrypoint and the executable's own sources are compiled where
    they sit too, so a generated sibling of `main` resolves beside it.

    An executable's own package may hold no `lib/` file (the executable may be its
    only member), and `generate_stable_package_config` keeps a package only if some
    file or `roots` entry names it. So its root is named in `roots`, or the package
    and the executable's own `package:` imports would be dropped.

    Args:
      packages: The deduplicated `DartPackageInfo` list, `own_package` included.
      dep_srcs: Flat list of the dependencies' transitive source Files.
      main: The entrypoint File.
      own_srcs: The rule's own `srcs` Files.
      own_package: The executable's own `DartPackageInfo`, or `None`.

    Returns:
      `struct(packages, srcs, main_input, main_arg, roots)`: the package list
      unchanged; every File the compile reads; the entrypoint File and the path to
      compile (its exec path); and exec-root package roots for
      `generate_stable_package_config`, whose keys are the packages it must keep.
    """
    srcs = list(dep_srcs) + [main] + list(own_srcs)
    roots = {}
    if own_package != None:
        root = own_package.lib_root
        rel = main.short_path[len(root) + 1:] if root else main.short_path
        roots[own_package.package_name] = main.path[:len(main.path) - len(rel)].rstrip("/")
    return struct(packages = packages, srcs = srcs, main_input = main, main_arg = main.path, roots = roots)

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
