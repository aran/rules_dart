"""Unit tests for dart_binary.bzl helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:dart_binary.bzl", "binary_output_basename")
load("//dart/private:dart_compile.bzl", "compile_quiet_flags")

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

def _aot_modes_compile_quietly_test_impl(ctx):
    # Regression: `dart compile exe|aot-snapshot` prints `Generated: <path>` on
    # stdout, and Bazel echoes any action output, so every build that compiled
    # a dart_binary showed a sandbox path. The other modes have no flag that
    # silences them.
    env = unittest.begin(ctx)
    asserts.equals(env, ["--verbosity=error"], compile_quiet_flags("exe"))
    asserts.equals(env, ["--verbosity=error"], compile_quiet_flags("aot-snapshot"))
    asserts.equals(env, [], compile_quiet_flags("kernel"))
    asserts.equals(env, [], compile_quiet_flags("jit-snapshot"))
    return unittest.end(env)

_exe_windows_test = unittest.make(_exe_gets_dot_exe_on_windows_test_impl)
_exe_other_test = unittest.make(_exe_bare_off_windows_test_impl)
_snapshot_test = unittest.make(_snapshot_modes_fixed_extensions_test_impl)
_quiet_test = unittest.make(_aot_modes_compile_quietly_test_impl)

def dart_binary_test_suite(name):
    """Registers the dart_binary.bzl helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    _exe_windows_test(name = "dart_binary_exe_windows_test", size = "small")
    _exe_other_test(name = "dart_binary_exe_other_test", size = "small")
    _snapshot_test(name = "dart_binary_snapshot_test", size = "small")
    _quiet_test(name = "dart_binary_quiet_test", size = "small")
    native.test_suite(
        name = name,
        tests = [
            ":dart_binary_exe_windows_test",
            ":dart_binary_exe_other_test",
            ":dart_binary_snapshot_test",
            ":dart_binary_quiet_test",
        ],
    )
