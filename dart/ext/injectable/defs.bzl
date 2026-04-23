"""Convenience macro for injectable_generator.

Two stages:

  1. Per-class metadata: `injectable_builder` runs over every file in
     `srcs` and emits a `<src>.injectable.json` shard.
  2. Per-init container: `injectable_config_builder` (aggregate) runs
     over the single file declaring `@InjectableInit` and, fed every
     metadata shard from stage 1, emits `<init>.config.dart` plus a
     `<init>.module.dart` shard for any module classes. Both outputs
     are wired through the shim's multi-output routing.
"""

load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen", "dart_library")

def injectable_library(
        name,
        srcs,
        package_name,
        language_version,
        init_src,
        deps = [],
        annotation_dep = "@pub_deps//:injectable",
        config = "",
        **kwargs):
    """A dart_library augmented by injectable_generator's two-stage codegen.

    Args:
      name: Wrapping `dart_library` target name.
      srcs: `.dart` source files in the package. Every entry goes through
        the metadata stage; the single file declaring `@InjectableInit`
        additionally goes through the config stage.
      package_name: Dart package name.
      language_version: Dart language version (`<major>.<minor>`).
      init_src: The `.dart` source file declaring `@InjectableInit`. Must
        be present in `srcs`. Drives stage 2 (config + module outputs).
      deps: Additional `dart_library`-shaped targets; `annotation_dep`
        is added automatically.
      annotation_dep: Runtime annotation-library label.
      config: Optional builder options as a JSON string.
      **kwargs: Forwarded to the wrapping `dart_library`.
    """
    if init_src not in srcs:
        fail("injectable_library {}: init_src {} must be listed in srcs.".format(
            name,
            init_src,
        ))

    # Derive stable target-name tokens from file paths so multiple
    # injectable_library targets in one BUILD don't collide.
    def _token(s):
        t = s
        if t.startswith("//"):
            t = t[2:]
        if ":" in t:
            t = t.split(":")[-1]
        return t.replace("/", "_").replace(".", "_").replace("-", "_")

    # Stage 1: emit per-class metadata shards.
    metadata_targets = []
    for src in srcs:
        token = _token(src)
        metadata_target = "_{name}_{token}_metadata".format(
            name = name,
            token = token,
        )
        dart_codegen(
            name = metadata_target,
            src = src,
            generator_bin = "@rules_dart//dart/ext/injectable:shim_metadata",
            output_suffixes = [".injectable.json"],
            package_name = package_name,
            language_version = language_version,
            deps = deps + [annotation_dep],
            config = config,
        )
        metadata_targets.append(":" + metadata_target)

    # Stage 2: aggregate config + module outputs for the init file.
    # The aggregate shim reads every .injectable.json shard via findAssets
    # (they're passed as input-asset-extra, exposing them through the
    # BuildStep); the output paths below derive from init_src's stem.
    init_token = _token(init_src)
    config_target = "_{name}_{token}_config".format(
        name = name,
        token = init_token,
    )
    init_stem = _stem_of(init_src)
    outputs = [
        init_stem + ".config.dart",
        init_stem + ".module.dart",
    ]
    dart_aggregate_codegen(
        name = config_target,
        srcs = [init_src] + metadata_targets,
        generator_bin = "@rules_dart//dart/ext/injectable:shim_config",
        outputs = outputs,
        package_name = package_name,
        language_version = language_version,
        deps = deps + [annotation_dep],
        config = config,
    )

    dart_library(
        name = name,
        srcs = srcs + [":" + config_target],
        deps = deps + [annotation_dep],
        package_name = package_name,
        language_version = language_version,
        **kwargs
    )

def _stem_of(label_or_path):
    """Extract the filename stem (minus `.dart`) from a label or path.

    `lib/src/foo.dart` → `lib/src/foo`. `:foo.dart` → `foo`. Used to
    derive sibling output paths.
    """
    s = label_or_path
    if s.startswith("//"):
        s = s[2:]
    if ":" in s:
        # For `//pkg:src/foo.dart` the file path is the part after `:`;
        # the package path is lost, but declare_file (via outputs=) only
        # needs the package-relative path anyway.
        s = s.split(":")[-1]
    if s.endswith(".dart"):
        s = s[:-len(".dart")]
    return s
