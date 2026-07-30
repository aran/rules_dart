Bump the Dart SDK to version $ARGUMENTS.

## Instructions

1. Read `docs/CHORES.md` § "Dart SDK Version Bump" for the complete file list.

2. Run `dart run tool/fetch_sdk_hashes.dart $ARGUMENTS` to get SHA-256 hashes for all platforms. If the script fails, stop and report the error.

3. Add the new version entry to `dart/private/versions.bzl` in the `TOOL_VERSIONS` dict, inserting it as the **first** entry (newest on top).

4. Update `dart_version` in all MODULE.bazel files listed in CHORES.md:

   - Root `MODULE.bazel`
   - All `e2e/*/MODULE.bazel` files that contain `dart.toolchain(dart_version = "...")`

5. Update the `dart_version` in the `README.md` installation snippet.

6. Leave `dart/runfiles/pubspec.yaml`'s `environment.sdk` alone unless the new SDK actually falls outside it. That package is published to pub.dev, so its lower bound stays as low as remains compatible rather than tracking the newest SDK (see CHORES.md).

7. Update `dart/tests/versions_test.bzl`:

   - Change the asserted version key in `_smoke_test_impl` to the new version
   - Change the version key used in `_platforms_test_impl`

8. Run `dart run tool/refresh_locks.dart` to regenerate all lock files.

9. Run `bazel test //dart/tests/...` to verify unit tests pass.

10. Pick one e2e workspace (e.g. `e2e/hello_world`) and run `bazel build //...` in it to verify the new SDK resolves correctly.

11. Commit with message: `chore: bump Dart SDK to $ARGUMENTS`
