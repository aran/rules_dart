"""Unit tests for common.bzl utilities."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/private:common.bzl",
    "asset_path_for",
    "check_single_root_package",
    "check_unreplaced_hooks",
    "generate_dev_package_config",
    "generate_package_config",
    "generate_package_config_content",
    "relative_path",
    "resolve_package_roots",
)

# --- generate_package_config_content tests (prefix-based) ---

def _empty_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    result = generate_package_config_content([], "../..")
    asserts.equals(env, '{"configVersion": 2, "packages": []}\n', result)
    return unittest.end(env)

def _single_package_test_impl(ctx):
    env = unittest.begin(ctx)
    pkg = struct(package_name = "foo", lib_root = "foo")
    result = generate_package_config_content([pkg], "..")
    asserts.true(env, '"configVersion": 2' in result)
    asserts.true(env, '"name": "foo"' in result)
    asserts.true(env, '"rootUri": "../foo"' in result)
    asserts.true(env, '"packageUri": "lib/"' in result)
    return unittest.end(env)

def _multiple_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [
        struct(package_name = "alpha", lib_root = "alpha"),
        struct(package_name = "beta", lib_root = "path/to/beta"),
    ]
    result = generate_package_config_content(pkgs, "../..")
    asserts.true(env, '"name": "alpha"' in result)
    asserts.true(env, '"rootUri": "../../alpha"' in result)
    asserts.true(env, '"name": "beta"' in result)
    asserts.true(env, '"rootUri": "../../path/to/beta"' in result)
    return unittest.end(env)

def _empty_lib_root_test_impl(ctx):
    env = unittest.begin(ctx)
    pkg = struct(package_name = "root_pkg", lib_root = "")
    result = generate_package_config_content([pkg], "../..")
    asserts.true(env, '"rootUri": "../.."' in result)
    return unittest.end(env)

# --- relative_path tests ---

def _relative_path_same_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ".", relative_path("a/b", "a/b"))
    return unittest.end(env)

def _relative_path_sibling_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "../c", relative_path("a/b", "a/c"))
    return unittest.end(env)

def _relative_path_deep_to_shallow_test_impl(ctx):
    env = unittest.begin(ctx)

    # e.g., config at bazel-out/cfg/bin/app -> source at pkg
    asserts.equals(env, "../../../pkg", relative_path("bazel-out/cfg/bin", "pkg"))
    return unittest.end(env)

def _relative_path_same_prefix_test_impl(ctx):
    env = unittest.begin(ctx)

    # e.g., config at bazel-out/cfg/bin/e2e/greeter -> generated at bazel-out/cfg/bin/proto
    asserts.equals(env, "../../proto", relative_path("bazel-out/cfg/bin/e2e/greeter", "bazel-out/cfg/bin/proto"))
    return unittest.end(env)

def _relative_path_to_root_test_impl(ctx):
    env = unittest.begin(ctx)

    # from deep path to exec-root ("")
    asserts.equals(env, "../../../../..", relative_path("bazel-out/cfg/bin/e2e/greeter", ""))
    return unittest.end(env)

def _relative_path_from_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "a/b", relative_path("", "a/b"))
    return unittest.end(env)

# --- generate_package_config / resolve_package_roots tests (exec-root-relative) ---
#
# The exec-root variant takes real `File` objects and a `File` config-output —
# but only reads `short_path`, `path`, `is_directory`, and `dirname`. We fake
# them with `struct`, matching the idiom in `source_set_test.bzl`.

def _fake_pkg(package_name, lib_root):
    return struct(package_name = package_name, lib_root = lib_root)

def _fake_src(short_path, path = None, is_directory = False):
    return struct(
        short_path = short_path,
        path = path if path != None else short_path,
        is_directory = is_directory,
        is_source = True,
        owner = struct(package = ""),
    )

def _fake_gen(short_path, owner_package):
    # Generated File: short_path = owner.package + "/" + declare_file path,
    # exec path carries the configuration prefix.
    return struct(
        short_path = short_path,
        path = "bazel-out/k8-fastbuild/bin/" + short_path,
        is_directory = False,
        is_source = False,
        owner = struct(package = owner_package),
    )

def _fake_config(dirname):
    return struct(dirname = dirname)

def _resolve_skips_source_less_test_impl(ctx):
    # `resolve_package_roots` only registers packages it can locate an
    # exec-root for. A package whose lib_root is non-empty but contributes
    # zero files to `all_srcs` must be absent from the returned dict.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("present_pkg", "present_pkg"),
        _fake_pkg("missing_pkg", "external/missing_pkg"),
    ]
    srcs = [_fake_src("present_pkg/lib/x.dart")]
    roots = resolve_package_roots(pkgs, srcs)
    asserts.true(env, "present_pkg" in roots)
    asserts.false(env, "missing_pkg" in roots, "source-less package must not be in roots")
    return unittest.end(env)

def _gpc_source_less_lib_root_skipped_test_impl(ctx):
    # Regression for the bug surfaced from rules_flutter: a package with a
    # non-empty lib_root but no Dart sources in the transitive closure
    # (asset/font-only pub deps like cupertino_icons, aggregate
    # `dart_library(srcs = [])` facades) must be silently omitted from the
    # generated package_config — not a fatal Starlark fail. If anything later
    # tries to import `package:<name>/…`, the Dart frontend reports a
    # localized URI-not-found at the import.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("present_pkg", "present_pkg"),
        _fake_pkg("missing_pkg", "external/missing_pkg"),
    ]
    srcs = [_fake_src("present_pkg/lib/x.dart")]
    result = generate_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "present_pkg"' in result)
    asserts.false(env, '"name": "missing_pkg"' in result, "source-less package must be omitted")
    return unittest.end(env)

def _gpc_all_source_less_test_impl(ctx):
    # Every package source-less: result is a well-formed package_config with
    # an empty `packages` array — never a Starlark fail.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("ghost", "external/ghost")]
    result = generate_package_config(pkgs, [], _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"configVersion": 2' in result)
    asserts.true(env, '"packages": [' in result)
    asserts.false(env, '"name": "ghost"' in result)
    return unittest.end(env)

def _gpc_root_package_no_srcs_still_falls_back_test_impl(ctx):
    # Regression guard: a root package (empty lib_root) with no sources keeps
    # its depth-based fallback rootUri. This path is distinct from the
    # source-less-non-root case and must keep working.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("root", "")]
    result = generate_package_config(pkgs, [], _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "root"' in result)
    asserts.true(env, '"rootUri":' in result)
    return unittest.end(env)

def _gpc_mixed_root_real_and_source_less_test_impl(ctx):
    # Root package + a real non-root package + a source-less non-root
    # package: the result lists the first two and omits the third.
    env = unittest.begin(ctx)
    pkgs = [
        _fake_pkg("root", ""),
        _fake_pkg("real", "real"),
        _fake_pkg("ghost", "external/ghost"),
    ]
    srcs = [
        _fake_src("lib/main.dart"),
        _fake_src("real/lib/r.dart"),
    ]
    result = generate_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin/app"))
    asserts.true(env, '"name": "root"' in result)
    asserts.true(env, '"name": "real"' in result)
    asserts.false(env, '"name": "ghost"' in result)
    return unittest.end(env)

# --- generate_dev_package_config tests (hot-reload multi-root) ---
#
# Reads `is_source` in addition to `short_path`/`path`, so use a fake that
# carries it.

def _fake_dev_src(short_path, path, is_source):
    return struct(
        short_path = short_path,
        path = path,
        is_source = is_source,
        is_directory = False,
    )

def _gdpc_no_assembly_matches_normal_test_impl(ctx):
    # No generated files anywhere → no scheme, no filesystem roots, and the
    # rootUris are the ordinary relative ones (behaves like the normal config).
    env = unittest.begin(ctx)

    # `dep` is an external repo: under bzlmod its files use the `../<repo>`
    # short_path convention while their exec `path` stays under `external/`.
    pkgs = [_fake_pkg("app", ""), _fake_pkg("dep", "../dep")]
    srcs = [
        _fake_dev_src("lib/main.dart", "lib/main.dart", True),
        _fake_dev_src("../dep/lib/d.dart", "external/dep/lib/d.dart", True),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.equals(env, [], res.filesystem_roots)
    asserts.equals(env, [], res.generated_source_paths)
    asserts.false(env, "org-dartlang-app" in res.content, "no scheme when nothing assembled")
    asserts.true(env, '"name": "app"' in res.content)
    asserts.true(env, '"name": "dep"' in res.content)
    return unittest.end(env)

def _gdpc_assembled_app_uses_scheme_and_roots_test_impl(ctx):
    # App package (root, lib_root="") mixes a source main.dart with a generated
    # user.g.dart → its rootUri becomes `org-dartlang-app:///` and both the
    # source exec root ("") and the generated exec root ("bazel-out/k8/bin")
    # are reported, source first. The pub dep stays relative.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("app", ""), _fake_pkg("dep", "../dep")]
    srcs = [
        _fake_dev_src("lib/main.dart", "lib/main.dart", True),
        _fake_dev_src("lib/user.dart", "lib/user.dart", True),
        _fake_dev_src("lib/user.g.dart", "bazel-out/k8/bin/lib/user.g.dart", False),
        _fake_dev_src("../dep/lib/d.dart", "external/dep/lib/d.dart", True),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.equals(env, "org-dartlang-app", res.scheme)
    asserts.true(
        env,
        '"name": "app", "rootUri": "org-dartlang-app:///"' in res.content,
        "assembled app package gets a scheme rootUri",
    )
    asserts.false(env, "org-dartlang-app:///.." in res.content, "external dep keeps relative rootUri")
    asserts.true(env, '"name": "dep"' in res.content)

    # Source root first ("" = execroot), then the generated bazel-out dir.
    asserts.equals(env, ["", "bazel-out/k8/bin"], res.filesystem_roots)
    asserts.equals(env, ["bazel-out/k8/bin/lib/user.g.dart"], res.generated_source_paths)
    asserts.equals(env, ["package:app/user.g.dart"], res.generated_source_uris)
    return unittest.end(env)

def _gdpc_non_root_assembled_package_test_impl(ctx):
    # A non-root package that is itself assembled gets `scheme:///<lib_root>`.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("sub", "pkgs/sub")]
    srcs = [
        _fake_dev_src("pkgs/sub/lib/a.dart", "pkgs/sub/lib/a.dart", True),
        _fake_dev_src("pkgs/sub/lib/a.g.dart", "bazel-out/k8/bin/pkgs/sub/lib/a.g.dart", False),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.true(
        env,
        '"name": "sub", "rootUri": "org-dartlang-app:///pkgs/sub"' in res.content,
    )
    asserts.equals(env, ["", "bazel-out/k8/bin"], res.filesystem_roots)
    return unittest.end(env)

def _gdpc_source_packages_lists_first_party_test_impl(ctx):
    # source_packages = (name, lib_root) for every package contributing a
    # FIRST-PARTY source file (is_source, short_path not under external/ or ../).
    # Pub/external deps are excluded (not editable, never watched). Order follows
    # `packages`.
    env = unittest.begin(ctx)

    # `pubdep` is external: its files carry the real `../<repo>` short_path, so
    # this exercises the `../`-prefix arm of the first-party exclusion (an
    # `external/`-prefixed short_path never occurs under bzlmod).
    pkgs = [
        _fake_pkg("app", ""),
        _fake_pkg("dep", "pkgs/dep"),
        _fake_pkg("pubdep", "../pubdep"),
    ]
    srcs = [
        _fake_dev_src("lib/main.dart", "lib/main.dart", True),
        _fake_dev_src("pkgs/dep/lib/d.dart", "pkgs/dep/lib/d.dart", True),
        _fake_dev_src("../pubdep/lib/p.dart", "external/pubdep/lib/p.dart", True),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.equals(env, [("app", ""), ("dep", "pkgs/dep")], res.source_packages)
    return unittest.end(env)

def _gdpc_source_packages_excludes_generated_only_test_impl(ctx):
    # A package whose only contributed file is generated (is_source=False) is not
    # an editable source package → excluded from source_packages.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("app", ""), _fake_pkg("genonly", "pkgs/genonly")]
    srcs = [
        _fake_dev_src("lib/main.dart", "lib/main.dart", True),
        _fake_dev_src(
            "pkgs/genonly/lib/g.g.dart",
            "bazel-out/k8/bin/pkgs/genonly/lib/g.g.dart",
            False,
        ),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.equals(env, [("app", "")], res.source_packages)
    return unittest.end(env)

def _gdpc_source_packages_includes_assembled_test_impl(ctx):
    # The feature's target case: an ASSEMBLED package (hand-written source +
    # generated member straddling tree and bazel-out) is still editable via its
    # source member, so it must appear in source_packages with its REAL lib_root
    # (not the assembled/scheme one). Guards against a regression where the
    # assembly path stops contributing to the path->package: map.
    env = unittest.begin(ctx)
    pkgs = [_fake_pkg("sub", "pkgs/sub")]
    srcs = [
        _fake_dev_src("pkgs/sub/lib/a.dart", "pkgs/sub/lib/a.dart", True),
        _fake_dev_src("pkgs/sub/lib/a.g.dart", "bazel-out/k8/bin/pkgs/sub/lib/a.g.dart", False),
    ]
    res = generate_dev_package_config(pkgs, srcs, _fake_config("bazel-out/k8/bin"))
    asserts.equals(env, [("sub", "pkgs/sub")], res.source_packages)
    return unittest.end(env)

def _check_single_root_ok_test_impl(ctx):
    # One root package (or none) is fine — no error.
    env = unittest.begin(ctx)
    asserts.equals(env, None, check_single_root_package([
        struct(package_name = "app", lib_root = ""),
        struct(package_name = "sub", lib_root = "pkgs/sub"),
    ]))
    asserts.equals(env, None, check_single_root_package([]))
    return unittest.end(env)

def _check_single_root_conflict_test_impl(ctx):
    # Two empty-lib_root packages must produce a diagnostic NAMING BOTH
    # packages. Regression: the old inline fail() applied `%` to a
    # placeholder-free fragment ("+" bound looser than "%"), so hitting the
    # condition crashed on the fail-message itself instead of reporting it.
    env = unittest.begin(ctx)
    err = check_single_root_package([
        struct(package_name = "app_a", lib_root = ""),
        struct(package_name = "app_b", lib_root = ""),
    ])
    asserts.true(env, err != None)
    asserts.true(env, "app_a" in err)
    asserts.true(env, "app_b" in err)
    asserts.true(env, "one root package" in err)
    return unittest.end(env)

def _hooks_ok_test_impl(ctx):
    # No hook, an empty hook string, and a producer that omits the field
    # entirely must all pass.
    env = unittest.begin(ctx)
    asserts.equals(env, None, check_unreplaced_hooks("//a:b", [
        struct(package_name = "fine", has_unreplaced_hook = ""),
        struct(package_name = "legacy"),
    ]))
    asserts.equals(env, None, check_unreplaced_hooks("//a:b", []))
    return unittest.end(env)

def _hooks_offender_test_impl(ctx):
    # Must name the target, each offending package, its hook path, and both
    # remedies — this message is the only thing standing between the user and
    # a runtime "couldn't resolve native function".
    env = unittest.begin(ctx)
    err = check_unreplaced_hooks("//app:bin", [
        struct(package_name = "fine", has_unreplaced_hook = ""),
        struct(package_name = "webcrypto", has_unreplaced_hook = "hook/build.dart"),
    ])
    asserts.true(env, err != None)
    asserts.true(env, "//app:bin" in err)
    asserts.true(env, "webcrypto" in err)
    asserts.true(env, "hook/build.dart" in err)
    asserts.true(env, "code_assets" in err)
    asserts.true(env, "ignore_hooks" in err)
    asserts.true(env, "fine" not in err)
    return unittest.end(env)

# --- asset_path_for tests ---

def _apf_source_under_lib_root_test_impl(ctx):
    env = unittest.begin(ctx)
    src = _fake_src("pkg/lib/a.dart")
    asserts.equals(env, "lib/a.dart", asset_path_for(src, "pkg"))
    return unittest.end(env)

def _apf_empty_lib_root_test_impl(ctx):
    env = unittest.begin(ctx)
    src = _fake_src("lib/a.dart")
    asserts.equals(env, "lib/a.dart", asset_path_for(src, ""))
    return unittest.end(env)

def _apf_generated_colocated_test_impl(ctx):
    # Codegen target in the same BUILD as the Dart package root: declared
    # path is already package-root-relative; the lib_root strip applies.
    env = unittest.begin(ctx)
    gen = _fake_gen("pkg/lib/a.g.dart", owner_package = "pkg")
    asserts.equals(env, "lib/a.g.dart", asset_path_for(gen, "pkg"))
    return unittest.end(env)

def _apf_generated_nested_package_test_impl(ctx):
    # Codegen target in a Bazel package NESTED below the Dart package root
    # with a cross-package src: dart_codegen declares the output at the
    # src's full short_path, so the generated short_path embeds it after
    # the owning package. The naive lib_root strip would return the wrong
    # `gen/pkg/lib/a.shard.json`.
    env = unittest.begin(ctx)
    gen = _fake_gen(
        "pkg/gen/pkg/lib/a.shard.json",
        owner_package = "pkg/gen",
    )
    asserts.equals(env, "lib/a.shard.json", asset_path_for(gen, "pkg"))
    return unittest.end(env)

def _apf_generated_sibling_package_test_impl(ctx):
    # Codegen target in a SIBLING Bazel package of the Dart package root:
    # the generated short_path is entirely outside lib_root (previously a
    # hard fail()); the owning package + declared path recover the asset.
    env = unittest.begin(ctx)
    gen = _fake_gen(
        "pkg/gen/pkg/app/lib/a.shard.json",
        owner_package = "pkg/gen",
    )
    asserts.equals(env, "lib/a.shard.json", asset_path_for(gen, "pkg/app"))
    return unittest.end(env)

def _apf_generated_deeper_build_test_impl(ctx):
    # Codegen target at `pkg/lib/BUILD` for Dart package root `pkg` with a
    # same-package src: dart_codegen strips its own package from the src's
    # short_path, so the generated short_path mirrors a source file's and
    # the standard lib_root strip stays correct.
    env = unittest.begin(ctx)
    gen = _fake_gen("pkg/lib/model.g.dart", owner_package = "pkg/lib")
    asserts.equals(env, "lib/model.g.dart", asset_path_for(gen, "pkg"))
    return unittest.end(env)

_t0_test = unittest.make(_empty_packages_test_impl)
_t1_test = unittest.make(_single_package_test_impl)
_t2_test = unittest.make(_multiple_packages_test_impl)
_t3_test = unittest.make(_empty_lib_root_test_impl)
_t4_test = unittest.make(_relative_path_same_dir_test_impl)
_t5_test = unittest.make(_relative_path_sibling_test_impl)
_t6_test = unittest.make(_relative_path_deep_to_shallow_test_impl)
_t7_test = unittest.make(_relative_path_same_prefix_test_impl)
_t8_test = unittest.make(_relative_path_to_root_test_impl)
_t9_test = unittest.make(_relative_path_from_empty_test_impl)
_t10_test = unittest.make(_resolve_skips_source_less_test_impl)
_t11_test = unittest.make(_gpc_source_less_lib_root_skipped_test_impl)
_t12_test = unittest.make(_gpc_all_source_less_test_impl)
_t13_test = unittest.make(_gpc_root_package_no_srcs_still_falls_back_test_impl)
_t14_test = unittest.make(_gpc_mixed_root_real_and_source_less_test_impl)
_t15_test = unittest.make(_gdpc_no_assembly_matches_normal_test_impl)
_t16_test = unittest.make(_gdpc_assembled_app_uses_scheme_and_roots_test_impl)
_t17_test = unittest.make(_gdpc_non_root_assembled_package_test_impl)
_t18_test = unittest.make(_gdpc_source_packages_lists_first_party_test_impl)
_t19_test = unittest.make(_gdpc_source_packages_excludes_generated_only_test_impl)
_t20_test = unittest.make(_gdpc_source_packages_includes_assembled_test_impl)
_t21_test = unittest.make(_check_single_root_ok_test_impl)
_t22_test = unittest.make(_check_single_root_conflict_test_impl)
_t23_test = unittest.make(_apf_source_under_lib_root_test_impl)
_t24_test = unittest.make(_apf_empty_lib_root_test_impl)
_t25_test = unittest.make(_apf_generated_colocated_test_impl)
_t26_test = unittest.make(_apf_generated_nested_package_test_impl)
_t27_test = unittest.make(_apf_generated_sibling_package_test_impl)
_t28_test = unittest.make(_apf_generated_deeper_build_test_impl)
_t32_test = unittest.make(_hooks_ok_test_impl)
_t33_test = unittest.make(_hooks_offender_test_impl)

def common_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
        _t18_test,
        _t19_test,
        _t20_test,
        _t21_test,
        _t22_test,
        _t23_test,
        _t24_test,
        _t25_test,
        _t26_test,
        _t27_test,
        _t28_test,
        _t32_test,
        _t33_test,
    )
