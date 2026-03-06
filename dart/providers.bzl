"""Providers for Dart rules."""

DartInfo = provider(
    doc = "Information about a Dart library's sources and transitive dependencies.",
    fields = {
        "package_name": "str: The Dart package name for this library.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent; consumers derive exec-root paths from source File objects.",
        "transitive_srcs": "depset[File]: All transitive Dart source files, including this library's own sources.",
        "transitive_packages": "depset[DartPackageInfo]: Package metadata for this library and all transitive deps.",
    },
)

DartPackageInfo = provider(
    doc = "Metadata about a single Dart package, carried in depsets within DartInfo.",
    fields = {
        "package_name": "str: The Dart package name.",
        "lib_root": "str: The short_path-based path to the package root directory (parent of `lib/`). Configuration-independent.",
    },
)

DartPackageConfigInfo = provider(
    doc = "A generated `package_config.json` file that maps `package:` URIs to source locations.",
    fields = {
        "file": "File: The generated package_config.json.",
    },
)

DartCompileInfo = provider(
    doc = "Information about a compiled Dart output.",
    fields = {
        "executable": "File: The compiled output file.",
        "compile_mode": "str: The compilation mode used (`exe`, `aot-snapshot`, `kernel`, or `jit-snapshot`).",
    },
)
