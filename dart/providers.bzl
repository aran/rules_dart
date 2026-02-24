"""Providers for Dart rules."""

DartInfo = provider(
    doc = "Information about a Dart library's sources and transitive dependencies.",
    fields = {
        "package_name": "The Dart package name for this library.",
        "lib_root": "The workspace-relative path to the package root directory.",
        "transitive_srcs": "Depset of all transitive Dart source Files.",
        "transitive_packages": "Depset of DartPackageInfo providers for all transitive deps.",
    },
)

DartPackageInfo = provider(
    doc = "Lightweight info about a single Dart package for use in depsets.",
    fields = {
        "package_name": "The Dart package name.",
        "lib_root": "The workspace-relative path to the package root directory.",
    },
)

DartPackageConfigInfo = provider(
    doc = "Information about a generated package_config.json file.",
    fields = {
        "file": "The package_config.json File.",
    },
)

DartCompileInfo = provider(
    doc = "Information about a compiled Dart binary.",
    fields = {
        "executable": "The compiled executable File.",
        "compile_mode": "The compilation mode used (exe, aot-snapshot, kernel, jit-snapshot).",
    },
)
