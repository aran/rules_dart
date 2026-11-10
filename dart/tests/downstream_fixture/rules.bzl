"""Rules of another rule set, over `@rules_dart//dart:utils.bzl` alone.

`downstream_library` is what rules_flutter's `flutter_library` is to rules_dart,
`downstream_application` its `flutter_application` and `downstream_member` its
`flutter_test`: rules defined outside `dart/private`, declaring `package` with
`package_identity_attrs()` and building their package records with
`library_package` and `executable_package_record`. They load nothing but the
public surface, so they can only do what another rule set can.
"""

load("//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load("//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "PORTABLE_EXEC_GROUPS", "SUMMARY_ATTRS", "dart_analyzable_info", "dart_info", "executable_package_record", "library_package", "package_identity_attrs", "resolve_package_identity")

def _downstream_library_impl(ctx):
    package = library_package(ctx, ctx.files.srcs, ctx.files.resources)

    # What `resolve_package_identity` says is what `library_package` returns.
    identity = resolve_package_identity(ctx)
    if (identity.metadata, identity.package_name, identity.language_version) != (package.metadata, package.package_name, package.language_version):
        fail("%s: library_package and resolve_package_identity disagree" % ctx.label)
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.resources)),
        dart_info(
            ctx = ctx,
            packages = [package.record],
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
        ),
    ]

downstream_library = rule(
    implementation = _downstream_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "resources": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [DartInfo]),
    } | package_identity_attrs() | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

def _identity_agrees(ctx, identity, record):
    """Fails unless the record and the identity it was built from say the same."""
    if (identity.package_root, identity.package_name, identity.language_version, identity.license_file) != (record.package_root, record.package_name, record.language_version, record.license_file):
        fail("%s: the record and the identity disagree" % ctx.label)

def _downstream_application_impl(ctx):
    identity = resolve_package_identity(ctx)
    record = executable_package_record(ctx.label, identity)
    _identity_agrees(ctx, identity, record)
    providers = [
        DefaultInfo(),
        dart_analyzable_info(label = ctx.label, packages = [record]),
    ]

    # What a test built in this application's package names to be.
    if identity.metadata != None:
        providers.append(identity.metadata)
    return providers

# An executable that must be part of a declared package: `package` is required,
# in the rule's own words.
downstream_application = rule(
    implementation = _downstream_application_impl,
    attrs = package_identity_attrs(
        mandatory = True,
        doc = "The package this application is.",
    ),
)

def _downstream_member_impl(ctx):
    # Built in its application's package when it names one, else in its own.
    application = ctx.attr.application
    identity = resolve_package_identity(
        ctx,
        metadata = application[DartPackageMetadataInfo] if application else None,
    )
    record = executable_package_record(ctx.label, identity)
    _identity_agrees(ctx, identity, record)
    return [
        DefaultInfo(),
        dart_analyzable_info(label = ctx.label, packages = [record]),
    ]

# An executable taking its package from another target.
downstream_member = rule(
    implementation = _downstream_member_impl,
    attrs = {
        "application": attr.label(providers = [DartPackageMetadataInfo]),
    } | package_identity_attrs(),
)
