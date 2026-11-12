"""Checking a target's imports against its own dependencies.

Bazel's discipline on top of Dart's: a library may import only what its own
`deps` provide (strict deps), a file of its own package only if it or one of
its dependencies holds it, and — unless the `dart_layering_check` feature is
off, as rules_cc's `layering_check` — a package only if a *direct* dependency
provides it: one reached only through a dependency's dependency stops being
there when that dependency drops it.

Beyond the dependencies, a file may name only what the compiler can reach
through declared inputs, judged as the compiler spells it: a `dart:` library,
a `package:` URI that stays inside its package and that a dependency provides,
or a file the target holds (a part) or the target or its dependencies hold (an
import); the empty URI (`import '' as self;`) names the library itself. A
`file:` URI, another scheme, a URI with a query or fragment or a relative path
into a package's `lib/` from outside it (each a second copy of the library), or
a path out of the workspace is refused, with the spelling to use instead.

The checks read directives and nothing compiled, so each runs as a small
validation action per library. A `dart_library` checks itself, in its own
`_validation` output group, as rules_cc ties `layering_check` to the target:
any build of the library runs it, an analysis included. An executable checks
its own files, and `dart_import_check_aspect` reaches the libraries of other
rules (a `dart_proto_library`, say) that cannot check themselves, so building a
`dart_test` or a `dart_binary` runs every check its libraries need.
Conditional imports are checked on every branch, so the result is the same on
every platform.

The converse check, unless the `dart_unused_deps` feature is off: every entry
of a target's `deps` must be named by an `import` or `export` of one of its
files, on any branch, of its package's link hook, which is built from the
package's dependencies, or of a file the rule writes and compiles with them (a
test's bootstrap), which is not checked itself. An unused edge compiles nothing
in, but a change to the dependency still rebuilds and reruns everything above
it. A dependency whose rule returns `DartUsedWithoutImportInfo` (a Flutter plugin, registered by
native code) is exempt wherever it is listed. So is one whose own package
brings native code or data assets or a hook to the program, which a program
gets whether or not it imports the package (`@Native` names an asset by id),
and one that carries no Dart at all (a font), which has nothing to import. A
dependency needed only for its `resources`, read by path at run time, belongs
in `data`. Only a rule whose `deps` are its sources' imports is checked this
way: the rules that check
themselves (those with `LIBRARY_IMPORT_CHECKER_ATTRS`) and the executables.
A rule reached only by the aspect states its dependencies for its own reasons:
a `dart_proto_library`'s follow its `.proto` imports, some of them options its
generated Dart never names.

`kernel_tool`, which runs the check, is itself built from libraries: the rules
that build it (`dart_tool_binary`) reach their dependencies through
`without_import_check`, under which a library has no checker to depend on.

Another repository's targets are not checked: their dependencies are their
own (a pub package's are generated from its pubspec), and a file of one that
imports what none of them provides fails only a program that reaches it.
"""

load("//dart:providers.bzl", "DartImportCheckInfo", "DartInfo", "DartUsedWithoutImportInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "add_kernel_roots", "merge_package_records", "own_packages")
load(
    "//dart/private:dart_deps.bzl",
    "direct_dart_deps",
    "exported_libraries",
    "forwarded_library",
    "propagated_attrs",
    "propagated_toolchains",
    "reached_targets",
)
load("//dart/private:dart_module.bzl", "KERNEL_TOOL_ATTR", "kernel_package_config")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS")

visibility("//dart/...")

LAYERING_CHECK_FEATURE = "dart_layering_check"

UNUSED_DEPS_FEATURE = "dart_unused_deps"

# What `bazel run @rules_dart//dart/unused_deps` builds: for each checked
# target, the deps none of its files imports, as JSON.
UNUSED_DEPS_OUTPUT_GROUP = "dart_unused_deps"

_IMPORT_CHECK = str(Label("//dart/private:import_check"))

def _without_import_check_impl(_settings, _attr):
    return {_IMPORT_CHECK: False}

without_import_check = transition(
    implementation = _without_import_check_impl,
    inputs = [],
    outputs = [_IMPORT_CHECK],
)

# What a `dart_library` checks its imports with: `kernel_tool`, or nothing
# under `without_import_check`, where `kernel_tool` is what is being built.
LIBRARY_IMPORT_CHECKER_ATTRS = {
    "_import_checker": attr.label(
        default = Label("//dart/private:import_checker"),
        cfg = config.exec(PORTABLE),
    ),
}

def library_import_check(ctx, own):
    """A library's `_validation` output group: the check of its own files.

    A rule that calls it, with `LIBRARY_IMPORT_CHECKER_ATTRS` among its
    attributes, checks itself, so `dart_import_check_aspect` leaves it alone;
    its `srcs` (and `srcs_dir`, if it has one) are checked against its `deps`,
    the unused-dependency check included.

    Args:
      ctx: The library's rule context, with `LIBRARY_IMPORT_CHECKER_ATTRS` and
        `PORTABLE_EXEC_GROUPS`.
      own: The library's `DartPackageInfo` records (`DartInfo.packages`).

    Returns:
      A list holding the `OutputGroupInfo` (`_validation`, and
      `UNUSED_DEPS_OUTPUT_GROUP`), or empty when nothing is checked.
    """
    checker = ctx.attr._import_checker[DefaultInfo].files_to_run
    if checker.executable == None:
        return []
    checked = dart_import_check_action(
        ctx,
        kernel_tool = checker,
        name = ctx.label.name,
        srcs = ctx.files.srcs + getattr(ctx.files, "srcs_dir", []),
        own = own,
        deps = ctx.attr.deps,
        check_unused = True,
    )
    if not checked.validation:
        return []
    return [OutputGroupInfo(**{
        "_validation": depset([checked.validation]),
        UNUSED_DEPS_OUTPUT_GROUP: depset([checked.report] if checked.report else []),
    })]

def _package_name(pkg):
    return pkg.package_name

def _path(f):
    return f.path

def _add_layering_args(args, deps, indirect_deps):
    """The packages a target may import: its direct dependencies'.

    A dependency without sources of its own (a façade re-exporting its
    `deps`) stands for everything it reaches, and the target's
    `DartInfo.indirect_deps` (a generator's imports) are accepted by the
    package each of them has in its dependent's `DartInfo.deps`.
    """
    args.add("--check-layering")
    facades = []
    for dep in deps:
        if DartInfo not in dep:
            continue
        dep_info = dep[DartInfo]
        for pkg in own_packages(dep_info):
            args.add("--direct-package", pkg.package_name)
        if not getattr(dep_info, "srcs", None):
            facades.append(dep_info.transitive_packages)
        for wanted in indirect_deps:
            for package in getattr(dep_info, "deps", {}).get(wanted, ()):
                args.add("--direct-package", package)
    args.add_all(depset(transitive = facades), before_each = "--direct-package", map_each = _package_name, uniquify = True)

def _brings_native_assets(info):
    """Whether a dependency's own packages bring native code, data or hooks to a program."""
    for pkg in own_packages(info):
        if (getattr(pkg, "code_assets", ()) or getattr(pkg, "data_assets", ()) or
            getattr(pkg, "unreplaced_hook", "") or getattr(pkg, "link_hook", None) or
            getattr(pkg, "linked_code_assets", ())):
            return True
    return False

def _short_label(repo, label, home):
    """`label` as written from package `home`, its repository part `repo`.

    A label in `home` is `:name`, and one whose name is its package's last
    component drops the name, as a BUILD file may.
    """
    if not repo and label.package == home:
        return ":" + label.name
    if not label.package and repo and label.name == repo[1:]:
        return repo
    last = label.package.rpartition("/")[2]
    if label.name == last:
        return "%s//%s" % (repo, label.package)
    return "%s//%s:%s" % (repo, label.package, label.name)

def _display_label(ctx, label):
    """`label` as the target's own BUILD file can name it.

    A repository is named by its apparent name when the target's repository
    mapping confirms the one its canonical name suggests: `@rules_dart` for
    `rules_dart+`, `@foo` for `mod++ext+foo`. Otherwise its canonical name
    stays: an alias's actual target (a pub hub's), which the target names
    only through the alias, has no apparent name there.
    """
    canonical = label.repo_name
    if not canonical:
        return _short_label("", label, ctx.label.package)
    apparent = canonical[:-1] if canonical.endswith("+") else canonical.rpartition("+")[2]
    if apparent and ctx.package_relative_label("@%s//%s:%s" % (apparent, label.package, label.name)) == label:
        return _short_label("@" + apparent, label, ctx.label.package)
    return _short_label("@@" + canonical, label, ctx.label.package)

def _dependent_label(ctx):
    """The label of the BUILD file's entry that made the target.

    A macro's target (`flutter_test`'s `<name>.program`) takes its `deps`
    from the call, which is named by `generator_name`.
    """
    generator = getattr(ctx.attr, "generator_name", "")
    return "//%s:%s" % (ctx.label.package, generator or ctx.label.name)

def _add_unused_deps_args(ctx, args, deps):
    """Each Dart dependency, by what names it, for the unused check to judge.

    A dependency is named by a file it holds, else by a package it
    contributes, else by one it passes on (see `unused_deps.dart`). An exempt
    one is listed all the same, marked so it is never reported: an import of
    a file it holds names it, and not another dependency that reaches its
    package.
    """
    args.add("--check-unused")
    args.add("--dependent", _dependent_label(ctx))
    for dep in deps:
        if DartInfo not in dep:
            continue
        info = dep[DartInfo]
        srcs = getattr(info, "srcs", None) or []
        if not srcs and not info.transitive_packages:
            continue
        label = str(dep.label).replace("%", "%%")
        args.add("--dep", "%s\tname\t%s" % (str(dep.label), _display_label(ctx, dep.label)))
        if DartUsedWithoutImportInfo in dep or _brings_native_assets(info):
            args.add("--dep", "%s\texempt" % str(dep.label))
        args.add_joined("--dep", srcs, join_with = "\t", map_each = _path, format_joined = label + "\tfile\t%s", omit_if_empty = False, expand_directories = False)
        args.add_joined("--dep", own_packages(info), join_with = "\t", map_each = _package_name, format_joined = label + "\tpackage\t%s", omit_if_empty = False)
        args.add_joined("--dep", info.transitive_packages, join_with = "\t", map_each = _package_name, uniquify = True, format_joined = label + "\treach\t%s", omit_if_empty = False)

def dart_import_check_action(ctx, kernel_tool, name, srcs, own, deps, indirect_deps = [], check_cycle = False, check_unused = False, generator_input = False, generated = []):
    """Checks the imports of `srcs` against `deps`, as a validation action.

    Args:
      ctx: The rule or aspect context.
      kernel_tool: The `kernel_tool` executable, a File or its `FilesToRunProvider`.
      name: Basename for the result, unique in the package.
      srcs: The target's own Dart sources (or source directories).
      own: The `DartPackageInfo` records they belong to; empty for an
        executable stating no package.
      deps: The targets they may import from, each providing `DartInfo`.
      indirect_deps: Labels from `DartInfo.indirect_deps`.
      check_cycle: Whether `own` must be exactly one dependency cycle, judged
        from what `srcs` import, as a `dart_package_cycle`'s packages must.
      check_unused: Whether every one of `deps` must be named by an import
        or export of `srcs`, unless the `dart_unused_deps` feature is off:
        true where `deps` are the attribute the target's author writes.
      generator_input: Whether `srcs` are what a code generator reads before it
        writes their parts, which are then not checked.
      generated: Dart Files the rule writes and compiles with `srcs` (a
        test's bootstrap): what they import uses `deps`, and they are not
        checked themselves.

    Returns:
      A struct: `validation`, the result File to put in `_validation`, and
      `report`, the File the unused-dependency check writes what it finds to
      when the fixer asks (`UNUSED_DEPS_OUTPUT_GROUP`), each `None` when
      there is nothing to check: no Dart sources, a target of another
      repository, or for `report`, no unused check.
    """
    srcs = [f for f in srcs if f.is_directory or f.extension == "dart"]
    for f in generated:
        if f.extension != "dart":
            fail("%s: `generated` takes the Dart files the rule writes; %s is not one" % (ctx.label, f.short_path))
    if not srcs or ctx.label.workspace_name:
        return struct(validation = None, report = None)
    dep_infos = [dep[DartInfo] for dep in deps if DartInfo in dep]
    packages = depset(
        own,
        transitive = [info.transitive_packages for info in dep_infos],
    )
    dep_srcs = depset(transitive = [info.transitive_srcs for info in dep_infos])

    # Package records by name, the target's own first, for mapping files to
    # `package:` URIs; two hubs supplying one package agree on its name. A
    # package config is assembled here for every library, so the merge's
    # agreement check refuses two declarations of one package where a library
    # first reaches both, not only in the programs that use it.
    by_name = {pkg.package_name: pkg for pkg in merge_package_records(packages.to_list())}
    package_config = ctx.actions.declare_file(name + ".import_check_package_config.json")
    ctx.actions.write(package_config, kernel_package_config(by_name.values()))
    result = ctx.actions.declare_file(name + ".import_check")

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--label", str(ctx.label))
    args.add("--package-config", package_config)
    for pkg in own:
        args.add("--package-name", pkg.package_name)
        args.add("--package-root", pkg.package_root)

    # Every directory a file is read from, the result's included: a
    # dependency built in another configuration (a test's `defines`) has its
    # generated files in another output directory.
    add_kernel_roots(args, "--multi-root", depset(srcs + generated + [result], transitive = [dep_srcs]))
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    args.add_all(dep_srcs, before_each = "--dep-file", map_each = _path, expand_directories = False)
    args.add_all(packages, before_each = "--available-package", map_each = _package_name, uniquify = True)
    if LAYERING_CHECK_FEATURE not in ctx.disabled_features:
        _add_layering_args(args, deps, indirect_deps)
    if check_cycle:
        args.add("--check-cycle")
    uses = []
    check_unused = check_unused and UNUSED_DEPS_FEATURE not in ctx.disabled_features
    if check_unused:
        _add_unused_deps_args(ctx, args, deps)

        # A package's link hook is built from the package's dependencies, and
        # what the rule writes from the target's, so what they import is a
        # use of them; neither is the target's own to check.
        hooks = [pkg.link_hook for pkg in own if getattr(pkg, "link_hook", None)]
        uses = hooks + generated
        args.add_all(uses, before_each = "--use-src")
    if generator_input:
        args.add("--generator-input")
    args.add("--output", result)

    # The check names a dependency's file by its path alone, so only a
    # directory, which it lists, is an input: a body edit in a dependency
    # does not rerun the check of everything above it.
    inputs = depset(
        srcs + uses + [package_config],
        transitive = [getattr(info, "transitive_src_dirs", depset()) for info in dep_infos],
    )
    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["check", args],
        inputs = inputs,
        outputs = [result],
        mnemonic = "DartImportCheck",
        exec_group = PORTABLE,
        progress_message = "Checking Dart imports of %{label}",
        execution_requirements = PATH_MAPPING,
    )
    report = None
    if check_unused:
        # The same check, writing the deps it finds unused instead of
        # failing, for the fixer; built only when it asks.
        report = ctx.actions.declare_file(name + ".unused_deps.json")
        report_args = ctx.actions.args()
        report_args.add("--report", report)
        ctx.actions.run(
            executable = kernel_tool,
            arguments = ["check", args, report_args],
            inputs = inputs,
            outputs = [report],
            mnemonic = "DartUnusedDeps",
            exec_group = PORTABLE,
            progress_message = "Finding unused Dart deps of %{label}",
            execution_requirements = PATH_MAPPING,
        )
    return struct(validation = result, report = report)

def _import_check_aspect_impl(target, ctx):
    reached = reached_targets(ctx, DartImportCheckInfo)
    if DartInfo not in target:
        return [DartImportCheckInfo(stamps = depset(), exported = exported_libraries(reached))]
    info = target[DartInfo]
    forwarded = forwarded_library(info, reached)
    if forwarded != None:
        return [forwarded[DartImportCheckInfo]]
    direct = direct_dart_deps(ctx, info, reached, DartImportCheckInfo)
    if hasattr(ctx.rule.attr, "_import_checker"):
        # It checks itself (`library_import_check`): its `_validation` group
        # holds the result.
        groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
        results = [groups._validation] if hasattr(groups, "_validation") else []
    else:
        checked = dart_import_check_action(
            ctx,
            kernel_tool = ctx.executable._kernel_tool,
            name = ctx.label.name,
            srcs = getattr(info, "srcs", []),
            own = own_packages(info),
            deps = direct,
            indirect_deps = getattr(info, "indirect_deps", []),
        )
        results = [depset([checked.validation])] if checked.validation else []
    return [DartImportCheckInfo(
        stamps = depset(transitive = results + [dep[DartImportCheckInfo].stamps for dep in direct]),
        exported = {},
    )]

dart_import_check_aspect = aspect(
    implementation = _import_check_aspect_impl,
    attr_aspects = propagated_attrs,
    toolchains_aspects = propagated_toolchains,
    exec_groups = PORTABLE_EXEC_GROUPS,
    attrs = KERNEL_TOOL_ATTR,
    doc = "Checks the imports of every library an executable depends on; see `dart_import_check.bzl`.",
)

def import_check_output_groups(ctx, kernel_tool, srcs, own_package, deps, generated = []):
    """An executable's import-check output groups.

    `_validation` is its own files' check and its libraries';
    `UNUSED_DEPS_OUTPUT_GROUP` what the fixer reads of its own `deps`.

    Args:
      ctx: The executable's rule context; its `deps` carry the aspect.
      kernel_tool: The `kernel_tool` executable.
      srcs: The executable's own source Files.
      own_package: The `DartPackageInfo` it states, or `None`.
      deps: Its `deps`.
      generated: The Dart Files the rule writes and compiles with `srcs`, a
        test's bootstrap say. What they import counts as a use of `deps`,
        and they are not checked for what they import.

    Returns:
      A dict of output group name to depset, for `OutputGroupInfo(**groups)`.
    """
    checked = dart_import_check_action(
        ctx,
        kernel_tool,
        ctx.label.name,
        srcs,
        [own_package] if own_package != None else [],
        deps,
        check_unused = True,
        generated = generated,
    )
    return {
        "_validation": depset(
            [checked.validation] if checked.validation else [],
            transitive = [dep[DartImportCheckInfo].stamps for dep in deps if DartImportCheckInfo in dep],
        ),
        UNUSED_DEPS_OUTPUT_GROUP: depset([checked.report] if checked.report else []),
    }
