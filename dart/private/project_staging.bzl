"""Hermetic staged-project assembly for rules that need a real project layout.

`dart compile js|wasm` accepts no `--packages` flag and `dart analyze` wants a
project directory, so both resolve packages by walking up from their input to a
`.dart_tool/package_config.json`. This module stages that layout entirely from
declared artifacts — no `mktemp`, no shell — as sibling outputs:

    <name>.proj/.dart_tool/package_config.json   (declared file)
    <name>.proj/src/...                          (tree artifact; workspace-relative paths)
    <name>.extpkgs/<pkg>/...                     (one tree artifact per external package)

Main-repo sources (hand-written and generated) merge into one `src` tree at
their workspace-relative paths, so every main-repo package's `lib_root` is a
real directory under `src/`. External (pub) packages cannot share that tree —
`copy_to_directory` maps external files repo-relative, so two pub spokes would
collide at `lib/...` — and get one tree each, referenced from the config via a
`../../` rootUri (package resolution follows rootUris outside the project dir).
"""

load("//dart/private:source_set.bzl", "assemble_source_dir", "package_for")

def mangle_package_dir(name):
    """Returns `name` with path-hostile characters replaced for use as a dir name.

    Args:
      name: A Dart package name (or any string).

    Returns:
      The mangled string (`/`, `:`, `.`, `+` become `_`).
    """
    for ch in ["/", ":", ".", "+"]:
        name = name.replace(ch, "_")
    return name

def _external_sub_path(lib_root):
    """Returns the repo-relative directory of an external `lib_root`.

    An external `lib_root` is `../<repo>[/<sub>]`; `copy_to_directory` stages
    external files at their repo-relative paths, so the package root inside
    its staged tree is `<sub>` (usually empty — pub spokes keep `lib/` at the
    repo root).

    Args:
      lib_root: The external package's `lib_root` (`../`-prefixed).

    Returns:
      The repo-relative sub path string (possibly empty).
    """
    parts = lib_root.split("/")
    return "/".join(parts[2:])

def staged_package_config_content(packages, ext_staged, proj_name):
    """Builds package_config.json content for the staged-project layout.

    The config lives at `<proj_name>.proj/.dart_tool/package_config.json`:
    main-repo packages resolve to `../src[/<lib_root>]`, external packages to
    `../../<proj_name>.extpkgs/<mangled>[/<sub>]`.

    Args:
      packages: List of DartPackageInfo providers.
      ext_staged: Dict of package_name -> True for external packages that
        actually have a staged tree (those without one are skipped — nothing
        to point at).
      proj_name: The staging name prefix (the rule's label name).

    Returns:
      String content of the package_config.json file.
    """
    entries = []
    for pkg in packages:
        if pkg.lib_root.startswith("../"):
            if pkg.package_name not in ext_staged:
                continue
            root_uri = "../../{}.extpkgs/{}".format(
                proj_name,
                mangle_package_dir(pkg.package_name),
            )
            sub = _external_sub_path(pkg.lib_root)
            if sub:
                root_uri += "/" + sub
        elif pkg.lib_root:
            root_uri = "../src/" + pkg.lib_root
        else:
            root_uri = "../src"
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def pubspec_stub(packages):
    """Builds the `pubspec.yaml` the staged project is analyzed against.

    The analyzer resolves imports through `package_config.json`, never through
    this file — but lint rules read it, so it has to be a *valid* pubspec, not
    just a parseable one. A placeholder name trips `package_names`, and every
    cross-package import trips `depend_on_referenced_packages` unless the
    package is listed here. Both fire on the harness rather than on the code
    under analysis, so a strict ruleset would blame the user for rules_dart's
    staging. Dependencies are sorted because `sort_pub_dependencies` would be
    the next one.

    Constraints are `any`: nothing resolves them, and a real constraint here
    would be a second place to keep a version in sync.

    Shared by `dart_analyze_test` and `dart_fix` rather than written out in
    each: fixes are driven by the lints a project reports, so the two staging
    the same project is what lets `bazel run :fix` turn a red analyze green.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`) — every
        package the staged `package_config.json` will carry.

    Returns:
      The pubspec file's contents, as a string.
    """
    lines = ["name: analyze_stub", "environment:", '  sdk: ">=3.0.0 <4.0.0"']
    names = sorted([p.package_name for p in packages if p.package_name])
    if names:
        lines.append("dependencies:")
        for name in names:
            lines.append("  %s: any" % name)
    return "\n".join(lines) + "\n"

def stage_dart_project(ctx, packages, all_srcs, extra_proj_files = {}):
    """Stages packages and sources into a hermetic Dart project layout.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of DartPackageInfo (from `collect_packages`).
      all_srcs: Flat list of Files to stage (the rule's own srcs/main plus the
        flattened transitive closure).
      extra_proj_files: Dict of `<filename> -> content string` written as
        declared files directly under `<name>.proj/` (e.g. a `pubspec.yaml`
        stub for `dart analyze`).

    Returns:
      struct(
        proj_path: exec path of the `<name>.proj` directory,
        src_tree: the `src` tree artifact File,
        package_config: the written package_config File,
        inputs: list of Files to add to the consuming action's inputs,
      )
    """
    name = ctx.label.name

    ext_pkgs = [p for p in packages if p.lib_root.startswith("../")]
    main_files = []
    ext_files_by_pkg = {}
    for f in all_srcs:
        if f.short_path.startswith("../"):
            # External files matching no package have no package: URI to
            # serve; nothing can resolve them from the staged project.
            owner = package_for(f.short_path, ext_pkgs)
            if owner != None:
                ext_files_by_pkg.setdefault(owner, []).append(f)
        else:
            main_files.append(f)

    src_tree = assemble_source_dir(
        ctx,
        name + ".proj/src",
        main_files,
        # Keep workspace-relative paths: each package's lib_root must be a
        # real directory under src/ for the rootUris above to hold.
        root_paths = [],
    )

    inputs = [src_tree]
    ext_staged = {}
    for pkg_name, files in ext_files_by_pkg.items():
        tree = assemble_source_dir(
            ctx,
            "{}.extpkgs/{}".format(name, mangle_package_dir(pkg_name)),
            files,
            root_paths = [],
            include_external_repositories = ["*"],
        )
        ext_staged[pkg_name] = True
        inputs.append(tree)

    package_config = ctx.actions.declare_file(name + ".proj/.dart_tool/package_config.json")
    ctx.actions.write(
        output = package_config,
        content = staged_package_config_content(packages, ext_staged, name),
    )
    inputs.append(package_config)

    for filename, content in extra_proj_files.items():
        extra = ctx.actions.declare_file(name + ".proj/" + filename)
        ctx.actions.write(output = extra, content = content)
        inputs.append(extra)

    return struct(
        proj_path = src_tree.dirname,
        src_tree = src_tree,
        package_config = package_config,
        inputs = inputs,
    )
