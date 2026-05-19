# Changelog

## 0.0.0-dev

- Add bzlmod `_repo_mapping` support: `rlocation` translates apparent
  repo names to canonical names using the `_repo_mapping` file Bazel
  stages at the runfiles root. New `Runfiles.create({String
sourceRepository})` parameter and `Runfiles.forRepo(String)` view let
  non-main-module callers spell their own canonical repo. Default
  behavior (main-module callers) is unchanged. Adds
  `Runfiles.parseRepoMapping(String)` and `Runfiles.fromState(...)` as
  low-level helpers for tests and embedders.
- Initial release.
