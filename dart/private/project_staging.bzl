"""Hermetic staged-project assembly for rules that need a real project layout.

`dart compile js|wasm` accepts no `--packages` flag and `dart analyze` wants a
project directory, so both resolve packages by walking up from their input to a
`.dart_tool/package_config.json`. This module stages that layout entirely from
declared artifacts — no `mktemp`, no shell — as sibling outputs:

    <name>.proj/.dart_tool/package_config.json   (declared file)
    <name>.proj/src/...                          (tree artifact; workspace-relative paths)
    <name>.proj/src/<package_root>/pubspec.yaml      (stub, one per home package)
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
assembled into `<name>.pkgs/<pkg>`.
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
`<name>.proj` itself, its path relative to it `src/<package_root>/lib/…`, and
those lints silently decline. The stubs restore each package's true root; a
nested pubspec does not split analysis contexts (context roots split on
options/package_config files, not pubspecs — `ContextLocatorImpl`, verified
on Dart 3.12.2), so options still come from the nearest `analysis_options.yaml`
above each file, never from a pubspec's position.
"""

load("//dart/private:common.bzl", "default_language_version", "derived_pubspec", "package_exec_root", "relative_path")
load("//dart/private:source_set.bzl", "assemble_source_dir", "package_record_for_index", "package_record_index")

visibility("//dart/...")

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

def _external_sub_path(package_root):
    """Returns the repo-relative directory of an external `package_root`.

    An external `package_root` is `../<repo>[/<sub>]`; `copy_to_directory` stages
    external files at their repo-relative paths, so the package root inside
    its staged tree is `<sub>` (usually empty — pub spokes keep `lib/` at the
    repo root).

    Args:
      package_root: The external package's `package_root` (`../`-prefixed).

    Returns:
      The repo-relative sub path string (possibly empty).
    """
    parts = package_root.split("/")
    return "/".join(parts[2:])

def staged_package_config_content(packages, root_uris):
    """Builds package_config.json content for the staged-project layout.

    Args:
      packages: List of DartPackageInfo providers.
      root_uris: Dict of `(package_name, package_root)` to the record's rootUri,
        relative to the config's directory. Records without one are skipped:
        nothing is staged for them to point at.

    Returns:
      String content of the package_config.json file.
    """
    entries = []
    for pkg in packages:
        root_uri = root_uris.get((pkg.package_name, pkg.package_root))
        if root_uri == None:
            continue
        lv = ""
        if pkg.language_version:
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

def pubspec_stub(packages, dart_sdk_info, name = "analyze_stub"):
    """Builds a `pubspec.yaml` for the staged project or a package within it.

    The analyzer resolves imports through `package_config.json`, never through
    this file — but lint rules read it, so it has to be a *valid* pubspec, not
    just a parseable one. A placeholder name trips `package_names`, and every
    cross-package import trips `depend_on_referenced_packages` unless the
    package is listed here. Both fire on the harness rather than on the code
    under analysis, so a strict ruleset would blame the user for rules_dart's
    staging. Dependencies are sorted because `sort_pub_dependencies` would be
    the next one.

    `derived_pubspec` writes it: each dependency at the version the build
    uses when known, else `any`, and never the stub's own name;
    `depend_on_referenced_packages` special-cases the containing package, so a `package:self/…` import never
    needs a self-dependency (measured on Dart 3.12.2).

    The SDK constraint is `^<language_version>.0` for the package named
    `name` when it states a `language_version` (from its
    `dart_package_metadata`), so `sdk_version_since` judges the code
    against what the package declares. Otherwise it is that of
    `default_language_version`, the version the package compiles at.

    Pubspec-reading lints fire on the harness unless this is a valid pubspec,
    so the `dart_analyze` aspect stages one for both its analyze and its fix
    action.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`) — every
        package the staged `package_config.json` will carry.
      name: The pubspec's `name:` field. The default names the harness-level
        stub at the project root; per-package stubs pass the real package name
        so the analyzer attributes each staged file to its true package.
      dart_sdk_info: The toolchain's `DartSdkInfo`, whose version is that of a
        package that states no `language_version`.

    Returns:
      The pubspec file's contents, as a string.
    """
    sdk = "^%s.0" % default_language_version(dart_sdk_info)
    for p in packages:
        if p.package_name == name and p.language_version:
            sdk = "^%s.0" % p.language_version
            break
    return derived_pubspec(name, sdk, packages)

def _deepest_root_record(short_path, index):
    """The record whose `package_root` is the deepest directory holding `short_path`.

    Tries the path itself, then each ancestor directory, then the empty root.
    """
    parts = short_path.split("/")
    for i in range(len(parts), 0, -1):
        record = index.get("/".join(parts[:i]))
        if record != None:
            return record
    return index.get("")

def test_working_directory(short_path, packages, workspace_name):
    """Where a test runs, as `dart test` runs it: in its package's root.

    The package is the one whose root is the deepest directory holding the
    test, among the packages its build knows (its own and its closure's) in
    its own repository, as Dart gives a file to the innermost package. A test
    no such package holds runs at its repository's root, where Bazel runs
    every test.

    Args:
      short_path: The test file's `short_path`.
      packages: The test's `DartPackageInfo` records.
      workspace_name: The main repository's runfiles directory name.

    Returns:
      `struct(runfiles_path, test_path)`: the runfiles path of the directory to
      run in, and the test file's path from it.
    """
    if short_path.startswith("../"):
        repo_root = "/".join(short_path.split("/")[:2])
        same_repo = [p for p in packages if (p.package_root == repo_root or p.package_root.startswith(repo_root + "/"))]
    else:
        repo_root = ""
        same_repo = [p for p in packages if not p.package_root.startswith("../")]
    record = _deepest_root_record(short_path, package_record_index(same_repo))
    root = record.package_root if record != None else repo_root
    if root.startswith("../"):
        run_dir = root[3:]
    else:
        run_dir = workspace_name + "/" + root if root else workspace_name
    return struct(
        runfiles_path = run_dir,
        test_path = short_path[len(root) + 1:] if root else short_path,
    )

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
        home: dict of `(package_name, package_root)` of each home package record,
        src_files: the Files staged under `src/`,
        dep_files: dict of `(package_name, package_root)` to the Files of each
          package record resolved from outside the project,
      )
    """
    main = [p for p in packages if not p.package_root.startswith("../")]
    main_index = package_record_index(main)
    index = package_record_index(packages)
    home = {}
    for f in home_files:
        best = _deepest_root_record(f.short_path, main_index)
        if best != None:
            home[(best.package_name, best.package_root)] = True

    src_files = []
    dep_files = {}
    for f in files:
        owner = package_record_for_index(f.short_path, index)
        if owner != None and (owner.package_name, owner.package_root) not in home:
            dep_files.setdefault((owner.package_name, owner.package_root), []).append(f)
        elif not f.short_path.startswith("../"):
            src_files.append(f)

        # An external file no package owns has no `package:` URI to serve;
        # nothing could resolve it from the staged project.

    return struct(packages = packages, home = home, src_files = src_files, dep_files = dep_files)

def main_package_roots(layout):
    """Returns the home package roots that receive a stub pubspec.

    One entry per distinct `package_root`; when several package records share a
    root (the split-package case), the lexically-first name wins so the choice
    is deterministic.

    Args:
      layout: The `project_layout` struct.

    Returns:
      Sorted list of (package_root, package_name) tuples.
    """
    seen = {}
    for package_name, package_root in layout.home:
        prev = seen.get(package_root)
        if prev == None or package_name < prev:
            seen[package_root] = package_name
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
        ("src/%s/pubspec.yaml" % package_root) if package_root else "src/pubspec.yaml"
        for package_root, _ in main_package_roots(layout)
    ]

def in_place_root(files, package_root, output_root):
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
      package_root: The package record's `package_root`.
      output_root: The project's own output root (`File.root.path`).

    Returns:
      The exec path of the package root, or None when the files have no
      single root the project can name.
    """
    roots = {package_exec_root(f, package_root): True for f in files}
    if len(roots) != 1:
        return None
    for f in files:
        if not f.is_source and f.root.path != output_root:
            return None
    return roots.keys()[0]

def _assembled_root(ctx, name, key, files, shared_name):
    """Assembles one package record's files beside the project; returns its root."""
    package_name, package_root = key
    dir_name = mangle_package_dir(package_name)
    if shared_name:
        # One name, several roots: a directory each.
        dir_name += "/" + mangle_package_dir(package_root)
    if package_root.startswith("../"):
        tree = assemble_source_dir(
            ctx,
            "{}.pkgs/{}".format(name, dir_name),
            files,
            root_paths = [],
            include_external_repositories = ["*"],
        )
        sub = _external_sub_path(package_root)
        return tree.path + "/" + sub if sub else tree.path, tree
    tree = assemble_source_dir(
        ctx,
        "{}.pkgs/{}".format(name, dir_name),
        files,
        root_paths = [package_root] if package_root else [],
    )
    return tree.path, tree

def resolve_package_exec_roots_from_outside(ctx, name, dep_files, config_file, assemble = {}):
    """Decides where each package record is read from, and what that needs.

    A record whose files have one root the config can name is read where its
    files are. One that does not (split between the source tree and
    `bazel-out`, or built in another configuration), and each one in
    `assemble`, is assembled into `<name>.pkgs/<package>`, so
    the package is exactly the files Bazel declared for it.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      name: Prefix for the assembled trees.
      dep_files: Dict of `(package_name, package_root)` to the record's Files.
      config_file: The `package_config.json` File the roots are relative to.
      assemble: Dict of the `(package_name, package_root)` keys to assemble
        whatever their files' roots.

    Returns:
      A dict of key to `struct(root_uri, root, tree, files)`: the rootUri
      relative to the config, the package root's exec path, the assembled tree
      File (None when read in place) and the Files to add to the consuming
      action's inputs (the tree, or the record's own files).
    """
    names = {}
    for package_name, _ in dep_files:
        names[package_name] = names.get(package_name, 0) + 1
    resolved = {}
    for key, files in dep_files.items():
        root = None
        if key not in assemble:
            root = in_place_root(files, key[1], config_file.root.path)
        tree = None
        if root == None:
            root, tree = _assembled_root(ctx, name, key, files, names[key[0]] > 1)
        resolved[key] = struct(
            root_uri = relative_path(config_file.dirname, root),
            root = root,
            tree = tree,
            files = [tree] if tree != None else files,
        )
    return resolved

def stage_dart_project(ctx, layout, dart_sdk_info, extra_proj_files = {}, name = None):
    """Stages packages and sources into a hermetic Dart project layout.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      layout: The `project_layout` struct.
      dart_sdk_info: The toolchain's `DartSdkInfo` (see `pubspec_stub`).
      extra_proj_files: Dict of `<filename> -> content string` written as
        declared files directly under `<name>.proj/` (e.g. a `pubspec.yaml`
        stub for `dart analyze`).
      name: Prefix for the staged paths; defaults to the target's name. An
        aspect passes its own, so it cannot collide with the target's outputs.

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
    for package_root, package_name in main_package_roots(layout):
        stub = ctx.actions.declare_file("{}.pkgstubs/{}/pubspec.yaml".format(
            name,
            mangle_package_dir(package_root) if package_root else "_root",
        ))
        ctx.actions.write(stub, pubspec_stub(packages, dart_sdk_info, name = package_name))

        # Key on the stub's workspace-relative directory: with `root_paths=[]`
        # that is exactly the path prefix it would keep inside the tree.
        replace_prefixes[stub.short_path.rsplit("/", 1)[0]] = package_root
        stub_files.append(stub)

    src_tree = assemble_source_dir(
        ctx,
        name + ".proj/src",
        layout.src_files + stub_files,
        # Keep workspace-relative paths: each home package's package_root must be
        # a real directory under src/ for its rootUri to hold.
        root_paths = [],
        replace_prefixes = replace_prefixes,
    )
    package_config = ctx.actions.declare_file(name + ".proj/.dart_tool/package_config.json")

    inputs = [src_tree]
    root_uris = {}
    for key in layout.home:
        root_uris[key] = "../src/" + key[1] if key[1] else "../src"
    for key, resolved in resolve_package_exec_roots_from_outside(
        ctx,
        name,
        layout.dep_files,
        package_config,
    ).items():
        inputs.extend(resolved.files)
        root_uris[key] = resolved.root_uri

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
