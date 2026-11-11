"""What a Dart test rule needs to report line coverage under `bazel coverage`.

A test collects coverage from a Dart VM and writes it as an LCOV tracefile to
`$COVERAGE_DIR/<name>.dat`, which Bazel's coverage runner merges into the test's
`coverage.dat`. Files are reported by their path in the workspace, which no VM
knows: `coverage_converter` finds each script's file in the `COVERAGE_MANIFEST`
Bazel sets and in the `lib/` directories of the packages the test reaches.
It also reads the sources it reports, for the `// coverage:ignore-line`,
`-start`/`-end` and `-file` comments that leave lines out. `test_coverage` writes
the directories and where each source is in the runfiles, and names what the
test must carry: the sources Bazel instruments, in coverage builds only.
"""

load("//dart/private:common.bzl", "kernel_root_path", "runfiles_path")
load("//dart/private:dart_info.bzl", "package_lib_prefix")

visibility("//dart/...")

# A test rule merges these into its `attrs`.
COVERAGE_ATTRS = {
    # Run inside the test, so built for the platform the test runs on.
    "_coverage_converter": attr.label(
        default = Label("//dart:coverage_converter"),
        executable = True,
        cfg = "target",
    ),
    # Bazel's coverage runner merges the test's tracefiles with it. Only
    # `bazel coverage` builds it.
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
}

def test_coverage(ctx, packages, sources, deps):
    """What a test needs to convert its coverage, when built for `bazel coverage`.

    Args:
      ctx: The test rule's context; the rule merges `COVERAGE_ATTRS` into its
        `attrs`.
      packages: The `DartPackageInfo` records of every package the test runs
        (`collect_packages(deps)` and the test's own).
      sources: The test's own Dart source `File`s.
      deps: The test's dependency targets, whose `InstrumentedFilesInfo` names
        the sources Bazel instruments.

    Returns:
      `None` unless `ctx.configuration.coverage_enabled`. Otherwise a struct of
      `converter` (the `coverage_converter` executable's runfiles path, to
      `rlocation`), `sources` (the runfiles path of the file it takes as
      `--sources`) and `runfiles`, a `runfiles` to merge into the test's, which
      carries the sources the converter reads the `coverage:ignore` comments
      of. Nothing is needed in the environment: Bazel sets `COVERAGE_DIR` and
      `COVERAGE_MANIFEST` itself for a test it runs.
    """
    if not ctx.configuration.coverage_enabled:
        return None
    libs = {}
    for pkg in packages:
        prefix = kernel_root_path(package_lib_prefix(pkg.package_root))
        roots = libs.setdefault(pkg.package_name, [])
        if prefix not in roots:
            roots.append(prefix)

    # The sources Bazel may instrument: the test's own, and what its deps'
    # `--instrumentation_filter` admits. Their runfiles paths are written by
    # exec path, which is what `COVERAGE_MANIFEST` lists.
    instrumented = depset(
        sources,
        transitive = [dep[InstrumentedFilesInfo].instrumented_files for dep in deps if InstrumentedFilesInfo in dep],
    )
    files = {f.path: runfiles_path(f, ctx.workspace_name) for f in instrumented.to_list()}
    sources_file = ctx.actions.declare_file(ctx.label.name + ".coverage_sources.json")
    ctx.actions.write(output = sources_file, content = json.encode({"packages": libs, "files": files}))
    converter = ctx.executable._coverage_converter
    return struct(
        converter = runfiles_path(converter, ctx.workspace_name),
        sources = runfiles_path(sources_file, ctx.workspace_name),
        runfiles = ctx.runfiles(files = [sources_file, converter], transitive_files = instrumented).merge(
            ctx.attr._coverage_converter[DefaultInfo].default_runfiles,
        ),
    )
