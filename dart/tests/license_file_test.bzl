"""Tests for the license file a package record carries.

The pure rules are unit tests here: which root file a pub package's license is,
what a spoke states, when two records of one package disagree, and that a
merge or a copy keeps the license. The analysis tests, which read records off
real targets, are declared beside their fixtures in
`//dart/tests/license_file_fixture`. That `pub.from_lock()` finds the file on
disk is `e2e/examples/pub/git`'s to show.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartPackageInfo")
load("//dart/private:common.bzl", "collect_packages", "merge_package_records", "package_agreement_error", "package_license_file")
load("//dart/private:dart_info.bzl", "derived_package_info")
load("//dart/pub:pub_library.bzl", "DartPackageMemberInfo")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "choose_pub_license_file", "make_dart_library_build_content", "make_pub_member_build_content")
load(":small_suite.bzl", "small_unittest_suite")

def _file(short_path):
    return struct(short_path = short_path)

def _pkg(package_root, license_file = None, package_name = "ffi"):
    return DartPackageInfo(
        None,
        package_name = package_name,
        package_root = package_root,
        language_version = "",
        license_file = license_file,
    )

# --- choose_pub_license_file ---

def _choose_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "NOTICES", choose_pub_license_file(["LICENSE", "NOTICES", "README.md"]))
    asserts.equals(env, "LICENSE", choose_pub_license_file(["pubspec.yaml", "LICENSE"]))
    asserts.equals(env, "", choose_pub_license_file(["pubspec.yaml"]))

    # Exact names: `flutter build` reads neither of these.
    asserts.equals(env, "", choose_pub_license_file(["license", "Notices", "LICENSE.md", "COPYING"]))
    return unittest.end(env)

_choose_test = unittest.make(_choose_test_impl)

# --- what a spoke states ---

def _spoke_states_license_test_impl(ctx):
    env = unittest.begin(ctx)
    line = '    license_file = "NOTICES",\n'
    member = make_pub_member_build_content("p", "3.0", "1.0.0", license_file = "NOTICES")
    asserts.true(env, line in member, member)
    library = make_dart_library_build_content("p", [], "3.0", license_file = "NOTICES")
    asserts.true(env, line in library, library)
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0"),
        make_dart_library_build_content("p", [], "3.0"),
    ]:
        asserts.true(env, "license_file" not in content, content)
    return unittest.end(env)

_spoke_states_license_test = unittest.make(_spoke_states_license_test_impl)

# --- package_agreement_error ---

def _agreement_accepts_same_file_from_two_hubs_test_impl(ctx):
    # Two hubs fetch one package twice: different Files, one license.
    env = unittest.begin(ctx)
    asserts.equals(env, None, package_agreement_error([
        _pkg("../hub_a__ffi", _file("../hub_a__ffi/LICENSE")),
        _pkg("../hub_b__ffi", _file("../hub_b__ffi/LICENSE")),
    ]))
    return unittest.end(env)

def _agreement_rejects_different_files_test_impl(ctx):
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("../hub_a__ffi", _file("../hub_a__ffi/LICENSE")),
        _pkg("../hub_b__ffi", _file("../hub_b__ffi/NOTICES")),
    ])
    asserts.true(env, err != None, "different license files must be reported")
    for part in ["\"ffi\"", "license files", "LICENSE (../hub_a__ffi)", "NOTICES (../hub_b__ffi)", "license_file"]:
        asserts.true(env, part in err, "%s not in: %s" % (part, err))

    # One package split across targets, naming two files by the same name
    # but in different places, is two licenses too.
    err = package_agreement_error([
        _pkg("pkg", _file("pkg/LICENSE")),
        _pkg("pkg", _file("third_party/LICENSE")),
    ])
    asserts.true(env, err != None and "third_party/LICENSE (pkg)" in err, str(err))
    return unittest.end(env)

def _agreement_tolerates_one_sided_license_test_impl(ctx):
    # A producer that does not name one knows less; it does not disagree.
    env = unittest.begin(ctx)
    asserts.equals(env, None, package_agreement_error([
        _pkg("../hub_a__ffi"),
        _pkg("../hub_b__ffi", _file("../hub_b__ffi/LICENSE")),
        DartPackageInfo(None, package_name = "ffi", package_root = "../old", language_version = ""),
    ]))
    return unittest.end(env)

_agreement_accepts_same_file_from_two_hubs_test = unittest.make(_agreement_accepts_same_file_from_two_hubs_test_impl)
_agreement_rejects_different_files_test = unittest.make(_agreement_rejects_different_files_test_impl)
_agreement_tolerates_one_sided_license_test = unittest.make(_agreement_tolerates_one_sided_license_test_impl)

# --- merge and copy keep it ---

def _merge_adopts_license_test_impl(ctx):
    env = unittest.begin(ctx)
    license = _file("../b/LICENSE")
    merged = merge_package_records([_pkg("../a"), _pkg("../b", license)])
    asserts.equals(env, 1, len(merged))
    asserts.equals(env, "../a", merged[0].package_root)
    asserts.equals(env, license, package_license_file(merged[0]))
    return unittest.end(env)

def _derived_keeps_license_test_impl(ctx):
    env = unittest.begin(ctx)
    license = _file("pkg/LICENSE")
    out = derived_package_info(_pkg("pkg", license), package_root = "bazel-out/k8/bin/app.pkg.pkgsrcs")
    asserts.equals(env, license, out.license_file)
    asserts.equals(env, None, package_license_file(DartPackageInfo(None, package_name = "p", package_root = "", language_version = "")))
    return unittest.end(env)

_merge_adopts_license_test = unittest.make(_merge_adopts_license_test_impl)
_derived_keeps_license_test = unittest.make(_derived_keeps_license_test_impl)

def license_file_test_suite(name):
    """Registers the pure-helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _choose_test,
        _spoke_states_license_test,
        _agreement_accepts_same_file_from_two_hubs_test,
        _agreement_rejects_different_files_test,
        _agreement_tolerates_one_sided_license_test,
        _merge_adopts_license_test,
        _derived_keeps_license_test,
    )

# --- analysis tests, declared in //dart/tests/license_file_fixture ---

def _licenses(target):
    if DartPackageMemberInfo in target:
        packages = [target[DartPackageMemberInfo].package]
    else:
        packages = collect_packages([target])
    licenses = {}
    for p in packages:
        f = package_license_file(p)
        licenses[p.package_name] = f.short_path if f else ""
    return licenses

def _records_license_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ctx.attr.license_files, _licenses(analysistest.target_under_test(env)))
    return analysistest.end(env)

records_license_test = analysistest.make(
    _records_license_test_impl,
    attrs = {"license_files": attr.string_dict(doc = "package name -> its license's short_path, or \"\" for none.")},
)

def _conflicting_license_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is supplied more than once with different license files")
    return analysistest.end(env)

conflicting_license_test = analysistest.make(_conflicting_license_test_impl, expect_failure = True)
