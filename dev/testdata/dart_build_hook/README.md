# dart_build_hook

A package's `hook/build.dart` and `hook/link.dart` are stated as the
`build_hook` and `link_hook` of the library of its `lib/`, each through a
filegroup in `hook/`, so rules_dart fails every binary and test that reaches
the library until the package's `code_assets` replace the build hook, and
`dart_link_hook` runs the link hook. The link hook's imports are the library's
`deps`. The `dart_library` an earlier Gazelle made of the hooks is deleted. A
package that has Gazelle not see its hooks (`# gazelle:exclude
hook/build.dart`, `# gazelle:exclude hook/link.dart`) states none.
