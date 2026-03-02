"""Shared utilities for Dart rules."""

load("//dart:providers.bzl", "DartInfo")

# Official Bazel bash runfiles v3 initialization boilerplate.
# Sources runfiles.bash which provides rlocation() for cross-platform
# runfile resolution (directory, manifest, and .exe.runfiles).
# See: https://github.com/bazelbuild/rules_shell/blob/main/shell/runfiles/runfiles.bash
BASH_RUNFILES_INIT = """\
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$0.runfiles/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---"""

# Private attribute that makes the bash runfiles library available in the
# runfiles tree of rules that generate bash launcher scripts.
BASH_RUNFILES_ATTR = {
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
}

def collect_packages(deps):
    """Collect unique DartPackageInfo providers from transitive deps.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    packages = []
    seen = {}
    for dep in deps:
        info = dep[DartInfo]
        for pkg in info.transitive_packages.to_list():
            if pkg.package_name not in seen:
                seen[pkg.package_name] = True
                packages.append(pkg)
    return packages

def generate_package_config_content(packages, prefix):
    """Generate package_config.json content string.

    Args:
        packages: List of DartPackageInfo providers.
        prefix: Path prefix to prepend to each package's lib_root for rootUri.
                For dart_binary/dart_test: "../" * depth (output tree → execroot).
                For dart_analyze: ".." (.dart_tool/ → project root).

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    entries = []
    for pkg in packages:
        root_uri = prefix + "/" + pkg.lib_root if pkg.lib_root else prefix
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def collect_transitive_srcs(deps):
    """Collect all transitive source files from DartInfo deps.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        List of Files from the transitive source closure.
    """
    srcs = []
    for dep in deps:
        srcs.extend(dep[DartInfo].transitive_srcs.to_list())
    return srcs
