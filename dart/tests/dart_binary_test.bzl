"""Unit tests for dart_binary.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_binary.bzl", "binary_output_basename")

def _exe_gets_dot_exe_on_windows_test_impl(ctx):
    # Regression: a dart_binary's native executable must be named `<name>.exe`
    # on Windows. Otherwise the output is a bare `app`, and a consumer's
    # runfiles lookup for `app.exe` (the conventional Windows name) misses and
    # falls through to a non-existent path — so the exe can't be located/run.
    env = unittest.begin(ctx)
    asserts.equals(env, "app.exe", binary_output_basename("app", "exe", True))
    return unittest.end(env)

def _exe_bare_off_windows_test_impl(ctx):
    # Off Windows, a native executable has no extension.
    env = unittest.begin(ctx)
    asserts.equals(env, "app", binary_output_basename("app", "exe", False))
    return unittest.end(env)

def _snapshot_modes_fixed_extensions_test_impl(ctx):
    # Snapshot modes aren't native executables; their extensions don't vary by
    # platform (no `.exe` even on Windows).
    env = unittest.begin(ctx)
    asserts.equals(env, "app.aot", binary_output_basename("app", "aot-snapshot", True))
    asserts.equals(env, "app.dill", binary_output_basename("app", "kernel", True))
    asserts.equals(env, "app.jit", binary_output_basename("app", "jit-snapshot", True))
    asserts.equals(env, "app.aot", binary_output_basename("app", "aot-snapshot", False))
    return unittest.end(env)

_exe_windows_test = unittest.make(_exe_gets_dot_exe_on_windows_test_impl)
_exe_other_test = unittest.make(_exe_bare_off_windows_test_impl)
_snapshot_test = unittest.make(_snapshot_modes_fixed_extensions_test_impl)

def dart_binary_test_suite(name):
    """Registers the dart_binary.bzl helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _exe_windows_test(name = "dart_binary_exe_windows_test")
    _exe_other_test(name = "dart_binary_exe_other_test")
    _snapshot_test(name = "dart_binary_snapshot_test")
    native.test_suite(
        name = name,
        tests = [
            ":dart_binary_exe_windows_test",
            ":dart_binary_exe_other_test",
            ":dart_binary_snapshot_test",
        ],
    )
