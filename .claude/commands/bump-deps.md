Check and bump all `bazel_dep` versions in MODULE.bazel to their latest BCR releases.

## Instructions

1. Read `docs/CHORES.md` § "Bazel Module Dependency Bumps" for the file list.

2. Read the root `MODULE.bazel` and identify all `bazel_dep()` entries (both regular and dev dependencies). For each one, check its latest version on the Bazel Central Registry by fetching `https://registry.bazel.build/modules/{name}` and looking for the latest version.

3. For each dep that has a newer version available, update the `version` field in the root `MODULE.bazel`. Skip any that are already current. Report what you're updating.

4. Mirror version changes to the e2e workspaces that duplicate the same deps —
   see the list in CHORES.md rather than relying on memory, and grep
   `e2e/*/MODULE.bazel` for `bazel_dep` to catch any the list has missed.

   Bumping `sqlite3` also requires updating the exact version literal asserted
   in `e2e/ext_exemplar/sqlite3_binary/test/direct_test.dart`.

5. Regenerate all lock files: `dart run tool/refresh_locks.dart`

6. Run `bazel test //dart/tests/...` to verify unit tests pass.

7. Commit with message: `chore: bump bazel module dependencies`
