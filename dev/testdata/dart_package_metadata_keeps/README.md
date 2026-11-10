# dart_package_metadata_keeps

A `dart_package_metadata` already at the package's root is the package's.
Gazelle rewrites what it writes there from the package:
the language version from `pubspec.yaml` (3.12, not the stale 3.10), the build
hook it now has, and no license file, since the root has none. It keeps
`code_assets` and `version`, which only a person states, so running it again
changes nothing.
