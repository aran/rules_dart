"""Unit tests for the source-assembly helpers (`needs_source_assembly`, `package_for`).

Also covers `derived_package_info`, which `colocate_packages` uses to rewrite an
assembled package's `package_root`. That helper is the single place a
`DartPackageInfo` is copied, so the tests below pin what a copy carries — not
just the field the caller overrode.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs", "package_code_assets")
load("//dart/private:dart_info.bzl", "derived_package_info", "package_lib_prefix")
load("//dart/private:package_info.bzl", "raw_dart_package_info")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "colocate_packages", "needs_source_assembly", "package_for", "package_record_for", "package_record_for_index", "package_record_index")

def _fake_file(is_source):
    # needs_source_assembly only inspects File.is_source.
    return struct(is_source = is_source)

def _fake_src(short_path, is_source = True, is_directory = False):
    # colocate_packages inspects short_path, is_source, is_directory.
    return struct(short_path = short_path, is_source = is_source, is_directory = is_directory)

def _fake_pkg(package_name, package_root):
    # package_for only inspects DartPackageInfo.package_name and .package_root.
    return DartPackageInfo(None, package_name = package_name, package_root = package_root, language_version = "")

def _all_source_no_assembly_test_impl(ctx):
    # Pure source-tree files already share one directory → no assembly.
    env = unittest.begin(ctx)
    asserts.false(env, needs_source_assembly([_fake_file(True), _fake_file(True)]))
    return unittest.end(env)

def _any_generated_needs_assembly_test_impl(ctx):
    # Any generated member straddles source tree and bazel-out → assemble.
    env = unittest.begin(ctx)
    asserts.true(env, needs_source_assembly([_fake_file(True), _fake_file(False)]))
    asserts.true(env, needs_source_assembly([_fake_file(False)]))
    return unittest.end(env)

def _empty_no_assembly_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, needs_source_assembly([]))
    return unittest.end(env)

def _package_for_root_package_test_impl(ctx):
    # The root package (empty package_root) owns `lib/...` and nothing else.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("root", "")]
    asserts.equals(env, "root", package_for("lib/a.dart", pkgs))
    asserts.equals(env, "root", package_for("lib", pkgs))
    asserts.equals(env, None, package_for("other/a.dart", pkgs))
    return unittest.end(env)

def _package_for_longest_prefix_test_impl(ctx):
    # When two package_roots both prefix the path, the longest one wins.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("foo", "foo"), _fake_pkg("foobar", "foo/bar")]
    asserts.equals(env, "foobar", package_for("foo/bar/lib/x.dart", pkgs))
    asserts.equals(env, "foo", package_for("foo/lib/x.dart", pkgs))
    return unittest.end(env)

def _package_for_exact_dir_test_impl(ctx):
    # An assembled package directory (short_path == package_root) matches exactly.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("p", "pkg/p.pkgsrcs")]
    asserts.equals(env, "p", package_for("pkg/p.pkgsrcs", pkgs))
    return unittest.end(env)

def _package_for_non_root_only_claims_lib_test_impl(ctx):
    # A package in a subdirectory claims the same thing the root package does:
    # its `lib/` subtree, and nothing else in the directory. `test/`, `tool/`
    # and `bin/` files are not reachable by a `package:` URI, so co-locating
    # them into the package's assembled directory would only misplace them —
    # and, for a generated entrypoint, break the relative imports that resolved
    # from its real location.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("sub", "pkgs/sub")]
    asserts.equals(env, "sub", package_for("pkgs/sub/lib/a.dart", pkgs))
    asserts.equals(env, "sub", package_for("pkgs/sub/lib/nested/a.dart", pkgs))

    # The `lib` directory itself, mirroring the root package's `"lib"` case.
    asserts.equals(env, "sub", package_for("pkgs/sub/lib", pkgs))

    asserts.equals(env, None, package_for("pkgs/sub/test/a_test.dart", pkgs))
    asserts.equals(env, None, package_for("pkgs/sub/tool/gen.dart", pkgs))
    asserts.equals(env, None, package_for("pkgs/sub/bin/main.dart", pkgs))
    asserts.equals(env, None, package_for("pkgs/sub/pubspec.yaml", pkgs))

    # A sibling directory whose name merely starts with the package_root.
    asserts.equals(env, None, package_for("pkgs/subway/lib/a.dart", pkgs))
    return unittest.end(env)

def _package_for_external_and_nomatch_test_impl(ctx):
    # External-repo package_root prefix matches; an unrelated path matches nothing.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("foo", "../pub/foo")]
    asserts.equals(env, "foo", package_for("../pub/foo/lib/x.dart", pkgs))
    asserts.equals(env, None, package_for("other/lib/x.dart", pkgs))
    return unittest.end(env)

def _scan_oracle(short_path, packages):
    # The linear scan the index replaced, kept as the reference behaviour.
    best = None
    best_len = -1
    for p in packages:
        lr = p.package_root
        prefix = package_lib_prefix(lr)
        under_lib = short_path == prefix[:-1] or short_path.startswith(prefix)
        if not lr:
            if under_lib and best_len < 0:
                best = p
                best_len = 0
        elif under_lib or short_path == lr:
            if len(lr) > best_len:
                best = p
                best_len = len(lr)
    return best

def _index_nested_roots_test_impl(ctx):
    # The deepest root wins, and a `lib` inside a root is part of the root.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("root", ""), _fake_pkg("outer", "a"), _fake_pkg("inner", "a/lib/b"), _fake_pkg("deep", "a/lib/b/c")]
    index = package_record_index(pkgs)
    for path, want in {
        "lib/r.dart": "root",
        "a/lib/x.dart": "outer",
        "a/lib/b/x.dart": "outer",
        "a/lib/b/lib/x.dart": "inner",
        "a/lib/b/c/lib/x.dart": "deep",
        "a/lib/b/c/lib": "deep",
        "a/lib/b/c": "deep",
    }.items():
        asserts.equals(env, want, package_record_for_index(path, index).package_name, path)
    return unittest.end(env)

def _index_split_roots_test_impl(ctx):
    # One package at two roots (source tree and bazel-out): each file resolves
    # the record whose root holds it. A shared root keeps its first record.
    env = unittest.begin(ctx)
    src = _fake_pkg("split", "pkgs/split")
    gen = _fake_pkg("split", "bazel-out/k8-fastbuild/bin/pkgs/split")
    dup = _fake_pkg("other", "pkgs/split")
    index = package_record_index([src, gen, dup])
    asserts.true(env, package_record_for_index("pkgs/split/lib/a.dart", index) == src)
    asserts.true(env, package_record_for_index("bazel-out/k8-fastbuild/bin/pkgs/split/lib/a.g.dart", index) == gen)
    return unittest.end(env)

def _index_outside_packages_test_impl(ctx):
    # Files outside every package's `lib/`, and an empty path, own no record.
    env = unittest.begin(ctx)
    index = package_record_index([_fake_pkg("a", "pkgs/a"), _fake_pkg("ext", "../pub/ext")])
    for path in ["pkgs/a/test/t.dart", "pkgs/a/pubspec.yaml", "pkgs/b/lib/x.dart", "other/lib/x.dart", "lib/x.dart", "", "../pub/ext/test/t.dart"]:
        asserts.equals(env, None, package_record_for_index(path, index), path)
    return unittest.end(env)

def _index_matches_scan_test_impl(ctx):
    # The index agrees with the scan on every path of a tangled layout.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("root", ""),
        _fake_pkg("a", "a"),
        _fake_pkg("a2", "a"),
        _fake_pkg("inner", "a/lib/b"),
        _fake_pkg("gen", "bazel-out/k/bin/a"),
        _fake_pkg("ext", "../x/ext"),
    ]
    index = package_record_index(pkgs)
    for path in [
        "lib",
        "lib/x.dart",
        "lib/a/lib/x.dart",
        "a",
        "a/lib",
        "a/lib/x.dart",
        "a/lib/b",
        "a/lib/b/x.dart",
        "a/lib/b/lib/x.dart",
        "a/test/x.dart",
        "bazel-out/k/bin/a/lib/g.dart",
        "bazel-out/k/bin/a/test/g.dart",
        "../x/ext",
        "../x/ext/lib/e.dart",
        "../x/other/lib/e.dart",
        "zzz/lib/lib/lib.dart",
    ]:
        asserts.true(env, _scan_oracle(path, pkgs) == package_record_for_index(path, index), path)
        asserts.true(env, _scan_oracle(path, pkgs) == package_record_for(path, pkgs), path)
    return unittest.end(env)

def _colocate_loose_passthrough_test_impl(ctx):
    # A transitive source whose package is not in `packages` (e.g. a pub
    # transitive dep that rides along in transitive_srcs) is already co-located
    # in its own source location — it must pass through as a compile input, not
    # abort the build. No assembly is triggered here (all inputs are source).
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("myapp", "myapp")]
    matched = _fake_src("myapp/lib/a.dart")
    loose = _fake_src("../rules_dart++pub+dart_pub__meta/lib/meta.dart")
    packages2, srcs2 = colocate_packages(ctx, pkgs, [matched, loose])
    asserts.true(env, loose in srcs2, "loose pub source must pass through")
    asserts.true(env, matched in srcs2, "matched source must pass through")
    asserts.equals(env, 1, len(packages2))
    asserts.equals(env, "myapp", packages2[0].package_name)
    return unittest.end(env)

# Built raw, not through `DartPackageInfo(...)`: that takes the code assets as
# targets providing `DartCodeAssetInfo`, and these tests have values.
def _record(package_root, language_version, code_assets, unreplaced_hook):
    return raw_dart_package_info(
        label = None,
        package_name = "pkg",
        package_root = package_root,
        version = "",
        language_version = language_version,
        code_assets = code_assets,
        data_assets = (),
        unreplaced_hook = unreplaced_hook,
        link_hook = None,
        link_hook_assets = (),
        linked_code_assets = (),
        license_file = None,
        metadata = None,
    )

def _fake_asset(asset_id):
    # derived_package_info only moves these around; it never reads inside one.
    return struct(asset_id = asset_id)

def _derive_carries_every_field_test_impl(ctx):
    # The point of the helper: overriding `package_root` must not cost the record
    # anything else it was carrying. A field dropped here is dropped only for
    # packages that happened to need assembly, which is the hardest shape of
    # this bug to notice.
    env = unittest.begin(ctx)
    p = _record("old/root", "2.12", (_fake_asset("package:pkg/a.g.dart"),), "hook/build.dart")
    out = derived_package_info(p, package_root = "bazel-out/k8/bin/app.pkg.pkgsrcs")
    asserts.equals(env, "pkg", out.package_name)
    asserts.equals(env, "bazel-out/k8/bin/app.pkg.pkgsrcs", out.package_root)
    asserts.equals(env, "2.12", out.language_version)
    asserts.equals(env, ["package:pkg/a.g.dart"], [a.asset_id for a in out.code_assets])
    asserts.equals(env, "hook/build.dart", out.unreplaced_hook)
    return unittest.end(env)

def _derive_overrides_only_named_test_impl(ctx):
    # Overriding `code_assets` leaves `package_root` alone, and vice versa — the
    # two call sites each name exactly one field.
    env = unittest.begin(ctx)
    p = _record("keep/me", "3.0", (_fake_asset("package:pkg/a.g.dart"),), "")
    out = derived_package_info(p, code_assets = (_fake_asset("package:pkg/b.g.dart"),))
    asserts.equals(env, "keep/me", out.package_root)
    asserts.equals(env, "3.0", out.language_version)
    asserts.equals(env, ["package:pkg/b.g.dart"], [a.asset_id for a in out.code_assets])

    # An empty override is an override, not "keep what was there".
    emptied = derived_package_info(p, code_assets = ())
    asserts.equals(env, (), emptied.code_assets)
    return unittest.end(env)

_derive_carries_test = unittest.make(_derive_carries_every_field_test_impl)
_derive_overrides_test = unittest.make(_derive_overrides_only_named_test_impl)

# --- colocate_packages end-to-end -------------------------------------------
#
# The unit tests above pin the helper. This one pins the path that motivated
# it: a package with a generated source gets assembled, and the assembled
# record must still own the package's code assets. Before the helper, this
# list held a three-field struct for assembled packages and a full record for
# every other one — so assets went missing for exactly the packages that
# happened to use codegen.

def _colocate_probe_impl(ctx):
    packages = collect_packages(ctx.attr.deps)
    packages2, _ = colocate_packages(
        ctx,
        packages,
        collect_transitive_srcs(ctx.attr.deps).to_list(),
    )

    matches = [p for p in packages2 if p.package_name == ctx.attr.package_name]
    if len(matches) != 1:
        fail("%s: expected one %r record after colocation, got %d" %
             (ctx.label, ctx.attr.package_name, len(matches)))
    pkg = matches[0]

    if not pkg.package_root.endswith(".pkgsrcs"):
        fail(("%s: %r was not assembled (package_root %r) — this fixture must " +
              "contain a generated source, or it proves nothing.") %
             (ctx.label, ctx.attr.package_name, pkg.package_root))

    ids = sorted([a.asset_id for a in package_code_assets(pkg)])
    if ids != sorted(ctx.attr.expected_asset_ids):
        fail("%s: assembled %r carries assets %s, expected %s" %
             (ctx.label, ctx.attr.package_name, ids, sorted(ctx.attr.expected_asset_ids)))
    return [DefaultInfo(files = depset())]

colocate_probe = rule(
    implementation = _colocate_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "expected_asset_ids": attr.string_list(),
        "package_name": attr.string(mandatory = True),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Asserts an assembled package keeps its code assets through colocation.",
)
_all_source_test = unittest.make(_all_source_no_assembly_test_impl)
_any_generated_test = unittest.make(_any_generated_needs_assembly_test_impl)
_empty_test = unittest.make(_empty_no_assembly_test_impl)
_root_pkg_test = unittest.make(_package_for_root_package_test_impl)
_longest_prefix_test = unittest.make(_package_for_longest_prefix_test_impl)
_exact_dir_test = unittest.make(_package_for_exact_dir_test_impl)
_non_root_lib_only_test = unittest.make(_package_for_non_root_only_claims_lib_test_impl)
_external_nomatch_test = unittest.make(_package_for_external_and_nomatch_test_impl)
_index_nested_test = unittest.make(_index_nested_roots_test_impl)
_index_split_test = unittest.make(_index_split_roots_test_impl)
_index_outside_test = unittest.make(_index_outside_packages_test_impl)
_index_matches_scan_test = unittest.make(_index_matches_scan_test_impl)
_colocate_loose_test = unittest.make(_colocate_loose_passthrough_test_impl)

def source_set_test_suite(name):
    """Registers the source-assembly helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _all_source_test(name = "source_set_all_source_test", size = "small")
    _any_generated_test(name = "source_set_any_generated_test", size = "small")
    _empty_test(name = "source_set_empty_test", size = "small")
    _root_pkg_test(name = "source_set_package_for_root_test", size = "small")
    _longest_prefix_test(name = "source_set_package_for_longest_test", size = "small")
    _exact_dir_test(name = "source_set_package_for_exact_dir_test", size = "small")
    _non_root_lib_only_test(name = "source_set_package_for_non_root_lib_only_test", size = "small")
    _external_nomatch_test(name = "source_set_package_for_external_test", size = "small")
    _index_nested_test(name = "source_set_index_nested_test", size = "small")
    _index_split_test(name = "source_set_index_split_test", size = "small")
    _index_outside_test(name = "source_set_index_outside_test", size = "small")
    _index_matches_scan_test(name = "source_set_index_matches_scan_test", size = "small")
    _colocate_loose_test(name = "source_set_colocate_loose_test", size = "small")
    _derive_carries_test(name = "source_set_derive_carries_test", size = "small")
    _derive_overrides_test(name = "source_set_derive_overrides_test", size = "small")
    native.test_suite(
        name = name,
        tests = [
            ":source_set_all_source_test",
            ":source_set_any_generated_test",
            ":source_set_empty_test",
            ":source_set_package_for_root_test",
            ":source_set_package_for_longest_test",
            ":source_set_package_for_exact_dir_test",
            ":source_set_package_for_non_root_lib_only_test",
            ":source_set_package_for_external_test",
            ":source_set_index_nested_test",
            ":source_set_index_split_test",
            ":source_set_index_outside_test",
            ":source_set_index_matches_scan_test",
            ":source_set_colocate_loose_test",
            ":source_set_derive_carries_test",
            ":source_set_derive_overrides_test",
        ],
    )
