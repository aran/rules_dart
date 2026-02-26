Regenerate all MODULE.bazel.lock files.

## Instructions

1. Read `docs/CHORES.md` § "Lock File Refresh" for the workspace list.

2. Run `dart run tool/refresh_locks.dart` to regenerate lock files in all workspaces.

3. If any workspace fails, investigate and report the error.

4. Commit with message: `chore: refresh MODULE.bazel.lock files`
