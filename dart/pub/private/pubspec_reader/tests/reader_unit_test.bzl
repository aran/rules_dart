"""Unit tests for the host and URI helpers of the pubspec reader's tool repository."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub/private/pubspec_reader:reader.bzl", "file_uri", "host_platform")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility("//dart/...")

def _file_uri_test_impl(ctx):
    env = unittest.begin(ctx)

    # A Windows path has an empty authority before its drive, not the drive as host.
    asserts.equals(env, "file:///C:/Users/me/_bazel/external/yaml", file_uri("C:\\Users\\me\\_bazel\\external\\yaml"))
    asserts.equals(env, "file:///C:/a/b", file_uri("C:/a/b"))
    asserts.equals(env, "file:///home/me/.cache/x", file_uri("/home/me/.cache/x"))

    # Characters a URI path cannot hold are escaped, not read as a fragment or query.
    asserts.equals(env, "file:///C:/Users/John%20Doe/a%23b%3Fc%25d", file_uri("C:\\Users\\John Doe\\a#b?c%d"))
    asserts.equals(env, "file:///tmp/%2Bx%2B", file_uri("/tmp/+x+"))
    return unittest.end(env)

def _host_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos-arm64", host_platform(struct(name = "Mac OS X", arch = "aarch64")))
    asserts.equals(env, "macos-x64", host_platform(struct(name = "mac os x", arch = "x86_64")))
    asserts.equals(env, "linux-arm64", host_platform(struct(name = "linux", arch = "aarch64")))
    asserts.equals(env, "linux-x64", host_platform(struct(name = "linux", arch = "amd64")))
    asserts.equals(env, "windows-x64", host_platform(struct(name = "Windows 11", arch = "amd64")))
    return unittest.end(env)

_file_uri_test = unittest.make(_file_uri_test_impl)
_host_platform_test = unittest.make(_host_platform_test_impl)

def reader_unit_test_suite(name):
    small_unittest_suite(name, _file_uri_test, _host_platform_test)
