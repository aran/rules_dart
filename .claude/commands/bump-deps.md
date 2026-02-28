Check and bump all `bazel_dep` versions in MODULE.bazel to their latest BCR releases.

## Instructions

1. Read `docs/CHORES.md` § "Bazel Module Dependency Bumps" for the file list.

2. Read the root `MODULE.bazel` and identify all `bazel_dep()` entries (both regular and dev dependencies). For each one, check its latest version on the Bazel Central Registry by fetching `https://registry.bazel.build/modules/{name}` and looking for the latest version.

3. For each dep that has a newer version available, update the `version` field in the root `MODULE.bazel`. Skip any that are already current. Report what you're updating.

4. Mirror version changes to e2e workspaces that duplicate the same deps:

   - `e2e/smoke/MODULE.bazel` — `bazel_skylib`
   - `e2e/gazelle/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_go`
   - `e2e/cross_compile/MODULE.bazel` — `platforms`
   - Check other e2e MODULE.bazel files for any deps that may also need updating

5. Regenerate all lock files: `dart run tool/refresh_locks.dart`

6. Run `bazel test //dart/tests/...` to verify unit tests pass.

7. Commit with message: `chore: bump bazel module dependencies`
