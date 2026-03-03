Update GitHub Actions versions in all workflow files to their latest releases.

## Instructions

1. Read `docs/CHORES.md` § "GitHub Workflow Dependency Bumps" for the dependency list.

2. Grep all `.github/workflows/*.yaml` files for `uses:` lines to find current versions.

3. For each external dependency, check the latest version via the GitHub API:

   - `gh api repos/{owner}/{repo}/releases/latest --jq .tag_name`
   - For actions pinned to a commit SHA, check the repo's tags to find the
     latest version and its corresponding SHA.

4. Update each `uses:` reference to the latest version. Keep `actions/checkout`
   consistent across all workflow files.

5. For reusable workflows (`bazel-contrib/.github`, `bazel-contrib/publish-to-bcr`),
   review changelogs for new inputs or breaking changes before updating.

6. Commit with message: `chore: bump GitHub Actions versions`
