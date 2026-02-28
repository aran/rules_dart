Bump Bazel to version $ARGUMENTS.

## Instructions

1. Read `docs/CHORES.md` § "Bazel Version Bump" for the complete file list.

2. Update all `.bazelversion` files to contain `$ARGUMENTS`:

   - Root `.bazelversion`
   - All `e2e/*/.bazelversion` files

3. Determine if the **major** version changed (e.g. 8.x to 9.x). If so:

   - Update `.bcr/presubmit.yml` — change the `bazel:` matrix value (e.g. `"8.x"` to `"9.x"`)
   - Update `docs/ARCHITECTURE.md` — any prose mentioning the major Bazel version

4. Regenerate all lock files: `dart run tool/refresh_locks.dart`

5. Run `bazel test //dart/tests/...` to verify unit tests pass.

6. Commit with message: `chore: bump Bazel to $ARGUMENTS`
