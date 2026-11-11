# dart_build_hook

A package's `hook/build.dart` and `hook/link.dart` are stated as the
`build_hook` and `link_hook` of its `dart_package_metadata`, each through a
filegroup in `hook/`, so rules_dart fails every binary and test that reaches
the package until the metadata's `code_assets` or `data_assets` replace the
build hook, and a linked `dart_program_assets` runs the link hook. The link hook's imports
are the deps of the package's library. A `dart_library` of the hooks is
deleted. A package that has Gazelle not see its hooks (`# gazelle:exclude
hook/build.dart`, `# gazelle:exclude hook/link.dart`) states none.
