"""Hermetic staged-project assembly for rules that need a real project layout.

`dart compile js|wasm` accepts no `--packages` flag and `dart analyze` wants a
project directory, so both resolve packages by walking up from their input to a
`.dart_tool/package_config.json`. This module stages that layout entirely from
declared artifacts — no `mktemp`, no shell — as sibling outputs:

    <name>.proj/.dart_tool/package_config.json   (declared file)
    <name>.proj/src/...                          (tree artifact; workspace-relative paths)
    <name>.proj/src/<lib_root>/pubspec.yaml      (stub, one per home package)
    <name>.pkgs/<pkg>/...                        (tree artifact, per assembled package)

Only the *home* packages are copied into `src`: those whose root holds a file
the action works on (the files `dart analyze` checks, a web app's
entrypoint), with every file they own, plus the files no package owns. These
have to be inside the project: a file belongs to the package whose rootUri
contains it, and the analyzer reports only on files under the project.

Every other package is only resolved against, and its rootUri leads out of the
project to where its files already are, as `dart_binary`'s package config
does. A package with no single
location — its files split between the source tree and `bazel-out` — is
assembled into `<name>.pkgs/<pkg>`; so is every dependency of a `relocatable`
project, which is read through runfiles, where exec-root paths do not hold.
External packages are assembled at their repo-relative paths (two pub spokes
would collide at `lib/...` in one tree), hence one tree per package.

Each home package root also receives a stub `pubspec.yaml`. Imports
resolve through `package_config.json` alone, but the analyzer attributes a
file to a package by walking up to the *nearest enclosing pubspec.yaml*
(`findPackageFor` in `pkg/analyzer`'s pub workspace), and a family of lints —
`public_member_api_docs`, `always_use_package_imports`,
`prefer_relative_imports`, `avoid_renaming_method_parameters`, and every rule
consulting `WorkspacePackage.contains` — decides whether to fire from that
package's root (`isInLibDir` is `<package root>/lib` containing the file).
With only a project-level pubspec, a staged file's "package root" would be
`<name>.proj` itself, its path relative to it `src/<lib_root>/lib/…`, and
those lints silently decline. The stubs restore each package's true root; a
nested pubspec does not split analysis contexts (context roots split on
options/package_config files, not pubspecs — `ContextLocatorImpl`, verified
on Dart 3.12.2), so options still come from the nearest `analysis_options.yaml`
above each file, never from a pubspec's position.
"""

load("//dart/private:common.bzl", "package_root_of", "relative_path")
load("//dart/private:source_set.bzl", "assemble_source_dir", "package_record_for")

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

def staged_package_config_content(packages, root_uris):
    """Builds package_config.json content for the staged-project layout.

    Args:
      packages: List of DartPackageInfo providers.
      root_uris: Dict of `(package_name, lib_root)` to the record's rootUri,
        relative to the config's directory. Records without one are skipped:
        nothing is staged for them to point at.

    Returns:
      String content of the package_config.json file.
    """
    entries = []
    for pkg in packages:
        root_uri = root_uris.get((pkg.package_name, pkg.lib_root))
        if root_uri == None:
            continue
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

def pubspec_stub(packages, name = "analyze_stub", sdk_version = ""):
    """Builds a `pubspec.yaml` for the staged project or a package within it.

    The analyzer resolves imports through `package_config.json`, never through
    this file — but lint rules read it, so it has to be a *valid* pubspec, not
    just a parseable one. A placeholder name trips `package_names`, and every
    cross-package import trips `depend_on_referenced_packages` unless the
    package is listed here. Both fire on the harness rather than on the code
    under analysis, so a strict ruleset would blame the user for rules_dart's
    staging. Dependencies are sorted because `sort_pub_dependencies` would be
    the next one.

    Constraints are `any`: nothing resolves them, and a real constraint here
    would be a second place to keep a version in sync. The stub's own name is
    excluded from the dependency list; `depend_on_referenced_packages`
    special-cases the containing package, so a `package:self/…` import never
    needs a self-dependency (measured on Dart 3.12.2).

    The SDK constraint is `^<language_version>.0` for the package named
    `name` when it states a `language_version` (which is itself derived from
    the package's real constraint), so `sdk_version_since` judges the code
    against what the package declares. Otherwise it is `^<major>.<minor>.0` of
    the toolchain SDK (`sdk_version`), so "no version stated" means the newest,
    as it does for the format style; without `sdk_version` it is
    `>=3.0.0 <4.0.0`.

    Pubspec-reading lints fire on the harness unless this is a valid pubspec,
    so the `dart_analyze` aspect stages one for both its analyze and its fix
    action.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`) — every
        package the staged `package_config.json` will carry.
      name: The pubspec's `name:` field. The default names the harness-level
        stub at the project root; per-package stubs pass the real package name
        so the analyzer attributes each staged file to its true package.
      sdk_version: The toolchain SDK's version (e.g. `3.11.0`); the constraint
        for a package that states no `language_version`. Empty for none.

    Returns:
      The pubspec file's contents, as a string.
    """
    sdk = ">=3.0.0 <4.0.0"
    parts = sdk_version.split(".")
    if len(parts) >= 2:
        sdk = "^%s.%s.0" % (parts[0], parts[1])
    for p in packages:
        if p.package_name == name and getattr(p, "language_version", ""):
            sdk = "^%s.0" % p.language_version
            break
    lines = ["name: %s" % name, "environment:", '  sdk: "%s"' % sdk]
    names = sorted([
        p.package_name
        for p in packages
        if p.package_name and p.package_name != name
    ])
    if names:
        lines.append("dependencies:")
        for dep in names:
            lines.append("  %s: any" % dep)
    return "\n".join(lines) + "\n"

def _root_contains(root, short_path):
    return not root or short_path == root or short_path.startswith(root + "/")

def project_layout(packages, files, home_files):
    """Decides which files a staged project holds and which it points out to.

    A home package is the main-repo package whose root holds one of
    `home_files` — the deepest such root, as Dart attributes a file. Its files
    are staged under `src/` with the files no package owns; every other
    package's files stay outside the project (see the module docstring).

    Args:
      packages: List of DartPackageInfo (from `collect_packages`).
      files: Every File the project needs.
      home_files: The Files the action works on.

    Returns:
      struct(
        packages: `packages`,
        home: dict of `(package_name, lib_root)` of each home package record,
        src_files: the Files staged under `src/`,
        dep_files: dict of `(package_name, lib_root)` to the Files of each
          package record resolved from outside the project,
      )
    """
    main = [p for p in packages if p.package_name and not p.lib_root.startswith("../")]
    home = {}
    for f in home_files:
        best = None
        for p in main:
            if _root_contains(p.lib_root, f.short_path) and (best == None or len(p.lib_root) > len(best.lib_root)):
                best = p
        if best != None:
            home[(best.package_name, best.lib_root)] = True

    src_files = []
    dep_files = {}
    for f in files:
        owner = package_record_for(f.short_path, packages)
        if owner != None and (owner.package_name, owner.lib_root) not in home:
            dep_files.setdefault((owner.package_name, owner.lib_root), []).append(f)
        elif not f.short_path.startswith("../"):
            src_files.append(f)

        # An external file no package owns has no `package:` URI to serve;
        # nothing could resolve it from the staged project.

    return struct(packages = packages, home = home, src_files = src_files, dep_files = dep_files)

def main_package_roots(layout):
    """Returns the home package roots that receive a stub pubspec.

    One entry per distinct `lib_root`; when several package records share a
    root (the split-package case), the lexically-first name wins so the choice
    is deterministic.

    Args:
      layout: The `project_layout` struct.

    Returns:
      Sorted list of (lib_root, package_name) tuples.
    """
    seen = {}
    for package_name, lib_root in layout.home:
        prev = seen.get(lib_root)
        if prev == None or package_name < prev:
            seen[lib_root] = package_name
    return sorted(seen.items())

def staged_pubspec_paths(layout):
    """Project-relative paths of the per-package stub pubspecs staging writes.

    The `dart_analyze` aspect composes its wrapper `analysis_options.yaml`
    before calling `stage_dart_project`, so the stub paths it must exclude are
    computed here, from the same dedupe rule staging uses, rather than
    returned by it.

    Args:
      layout: The `project_layout` struct.

    Returns:
      Sorted list of `src/...` path strings, one per stub pubspec.
    """
    return [
        ("src/%s/pubspec.yaml" % lib_root) if lib_root else "src/pubspec.yaml"
        for lib_root, _ in main_package_roots(layout)
    ]

def in_place_root(files, lib_root, output_root):
    """Returns where a package's files sit, if the project can point there.

    A rootUri is written into the package config as text, which path mapping
    (`--experimental_output_paths=strip`) does not rewrite, while the action
    reading it sees every output directory as `bazel-out/cfg/bin`. A relative
    path survives that only between the source tree and the project's own
    output directory, so a package built in another configuration — the deps
    of a `dart_test` with `defines` — has to be assembled beside the project,
    as one split between the source tree and `bazel-out` does.

    Args:
      files: The package record's Files.
      lib_root: The package record's `lib_root`.
      output_root: The project's own output root (`File.root.path`).

    Returns:
      The exec path of the package root, or None when the files have no
      single root the project can name.
    """
    roots = {package_root_of(f, lib_root): True for f in files}
    if len(roots) != 1:
        return None
    for f in files:
        if not f.is_source and f.root.path != output_root:
            return None
    return roots.keys()[0]

def _assembled_root(ctx, name, key, files, shared_name):
    """Assembles one package record's files beside the project; returns its root."""
    package_name, lib_root = key
    dir_name = mangle_package_dir(package_name)
    if shared_name:
        # One name, several roots: a directory each.
        dir_name += "/" + mangle_package_dir(lib_root)
    if lib_root.startswith("../"):
        tree = assemble_source_dir(
            ctx,
            "{}.pkgs/{}".format(name, dir_name),
            files,
            root_paths = [],
            include_external_repositories = ["*"],
        )
        sub = _external_sub_path(lib_root)
        return tree.path + "/" + sub if sub else tree.path, tree
    tree = assemble_source_dir(
        ctx,
        "{}.pkgs/{}".format(name, dir_name),
        files,
        root_paths = [lib_root] if lib_root else [],
    )
    return tree.path, tree

def stage_dart_project(ctx, layout, relocatable = False, extra_proj_files = {}, name = None, sdk_version = ""):
    """Stages packages and sources into a hermetic Dart project layout.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      layout: The `project_layout` struct.
      relocatable: Whether the project is read somewhere other than the exec
        root (through runfiles), so every dependency is assembled beside it
        rather than referenced where it sits.
      extra_proj_files: Dict of `<filename> -> content string` written as
        declared files directly under `<name>.proj/` (e.g. a `pubspec.yaml`
        stub for `dart analyze`).
      name: Prefix for the staged paths; defaults to the target's name. An
        aspect passes its own, so it cannot collide with the target's outputs.
      sdk_version: The toolchain SDK's version, the staged SDK constraint of a
        package that states no `language_version`. Empty for the old default.

    Returns:
      struct(
        src_tree: the `src` tree artifact File,
        package_config: the written package_config File,
        proj_files: dict of `extra_proj_files` name -> the File written,
        inputs: list of Files to add to the consuming action's inputs,
      )
    """
    name = name or ctx.label.name
    packages = layout.packages

    # One stub pubspec per home package root (see the module docstring for
    # why lints need it). The stubs cannot be declared at their final paths —
    # `<name>.proj/src` is a tree artifact, and Bazel rejects declared files
    # under a declared directory — so each is written to a sibling
    # `.pkgstubs` staging spot and mapped into place by the same
    # `copy_to_directory` that assembles the tree.
    stub_files = []
    replace_prefixes = {}
    for lib_root, package_name in main_package_roots(layout):
        stub = ctx.actions.declare_file("{}.pkgstubs/{}/pubspec.yaml".format(
            name,
            mangle_package_dir(lib_root) if lib_root else "_root",
        ))
        ctx.actions.write(stub, pubspec_stub(packages, name = package_name, sdk_version = sdk_version))

        # Key on the stub's workspace-relative directory: with `root_paths=[]`
        # that is exactly the path prefix it would keep inside the tree.
        replace_prefixes[stub.short_path.rsplit("/", 1)[0]] = lib_root
        stub_files.append(stub)

    src_tree = assemble_source_dir(
        ctx,
        name + ".proj/src",
        layout.src_files + stub_files,
        # Keep workspace-relative paths: each home package's lib_root must be
        # a real directory under src/ for its rootUri to hold.
        root_paths = [],
        replace_prefixes = replace_prefixes,
    )
    package_config = ctx.actions.declare_file(name + ".proj/.dart_tool/package_config.json")

    inputs = [src_tree]
    root_uris = {}
    for key in layout.home:
        root_uris[key] = "../src/" + key[1] if key[1] else "../src"
    names = {}
    for package_name, _ in layout.dep_files:
        names[package_name] = names.get(package_name, 0) + 1
    for key, files in layout.dep_files.items():
        root = None if relocatable else in_place_root(files, key[1], package_config.root.path)
        if root != None:
            inputs.extend(files)
        else:
            root, tree = _assembled_root(ctx, name, key, files, names[key[0]] > 1)
            inputs.append(tree)
        root_uris[key] = relative_path(package_config.dirname, root)

    ctx.actions.write(
        output = package_config,
        content = staged_package_config_content(packages, root_uris),
    )
    inputs.append(package_config)

    proj_files = {}
    for filename, content in extra_proj_files.items():
        extra = ctx.actions.declare_file(name + ".proj/" + filename)
        ctx.actions.write(output = extra, content = content)
        inputs.append(extra)
        proj_files[filename] = extra

    return struct(
        src_tree = src_tree,
        package_config = package_config,
        proj_files = proj_files,
        inputs = inputs,
    )
