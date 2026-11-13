"""The package metadata a target's closure carries, as an SBOM tool reads it.

`package_metadata_files` collects the metadata file of each `package_metadata`
attached to a target in its deps' closure, and to the Dart toolchain they
build with, through each target's `package_metadata` attribute (which a
repository's `REPO.bazel` fills), as supply-chain's own aspect does.
`purls_test.dart` reads the purls in them.
"""

load("@package_metadata//providers:package_metadata_info.bzl", "PackageMetadataInfo")

_TOOLCHAIN = "@rules_dart//dart:toolchain_type"

_MetadataFilesInfo = provider(doc = "The package metadata files of a closure.", fields = ["files"])

def _metadata_aspect_impl(_target, ctx):
    direct = [m[PackageMetadataInfo].metadata for m in getattr(ctx.rule.attr, "package_metadata", []) if PackageMetadataInfo in m]
    transitive = []
    for name in ["deps", "members"]:
        for dep in getattr(ctx.rule.attr, name, []):
            if _MetadataFilesInfo in dep:
                transitive.append(dep[_MetadataFilesInfo].files)
    toolchain = ctx.rule.toolchains[_TOOLCHAIN] if _TOOLCHAIN in ctx.rule.toolchains else None
    if toolchain and _MetadataFilesInfo in toolchain:
        transitive.append(toolchain[_MetadataFilesInfo].files)
    return [_MetadataFilesInfo(files = depset(direct, transitive = transitive))]

_metadata_aspect = aspect(
    implementation = _metadata_aspect_impl,
    attr_aspects = ["deps", "members"],
    toolchains_aspects = [_TOOLCHAIN],
)

def _impl(ctx):
    files = depset(transitive = [d[_MetadataFilesInfo].files for d in ctx.attr.deps])
    return [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]

package_metadata_files = rule(
    implementation = _impl,
    attrs = {"deps": attr.label_list(mandatory = True, aspects = [_metadata_aspect])},
)
