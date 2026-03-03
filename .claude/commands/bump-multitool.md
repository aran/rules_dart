Update multitool-managed tools to their latest versions.

## Instructions

1. Read `docs/CHORES.md` § "Multitool Version Bumps" for context.

2. Read `multitool.lock.json` and identify the current versions of each tool.

3. For each tool, check its GitHub releases API for the latest version:
   - **typos**: `https://api.github.com/repos/crate-ci/typos/releases/latest`
   - **yamlfmt**: `https://api.github.com/repos/google/yamlfmt/releases/latest`

4. For each tool that has a newer version available:
   - Download archives for all platform variants listed in the lockfile
   - Compute SHA-256 hashes: `shasum -a 256 <file>`
   - Update the lockfile entry with new version URLs and hashes
   - Report what you're updating (old version -> new version)

5. Skip any tools that are already at the latest version.

6. Also update the `rev:` for yamlfmt and typos in `.pre-commit-config.yaml`
   to match the new versions.

7. Regenerate all lock files: `dart run tool/refresh_locks.dart`

8. Verify the updated tools work:
   - `bazel run @multitool//tools/yamlfmt -- -lint .`
   - `bazel run @multitool//tools/typos -- .`

9. Commit with message: `chore: bump multitool-managed tools`
