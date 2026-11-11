# dart_package_metadata_keeps_link_hook_assets

The data assets a package's link hook emits are named in its hook's code,
which Gazelle does not read, so a hand-written `link_hook_assets` on the
package's `dart_package_metadata` is kept while Gazelle rewrites the rest: the
language version from `pubspec.yaml` and the `link_hook` it finds in `hook/`.
