# dart_lang_version_every_target

A stated language version reaches every rule Gazelle writes, the package's
library and its codegen macro (`from_pubspec/`) alike, through the package's
`dart_package_metadata`, which each names with `package`, whether
`pubspec.yaml` (`from_pubspec/`), `# gazelle:dart_language_version`
(`from_directive/`) or a hand-written `dart_package_metadata` with neither
beside it (`from_metadata/`) states it.
