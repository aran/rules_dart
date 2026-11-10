# dart_lang_version_every_target

A stated language version reaches every library Gazelle writes, the plain
ones as well as the codegen chain's, whether `pubspec.yaml`
(`from_pubspec/`, with a directory of `lib/` split into its own BUILD file),
`# gazelle:dart_language_version` (`from_directive/`) or a
`dart_package_metadata` (`from_metadata/`) states it.
