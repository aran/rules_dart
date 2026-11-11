# dart_lang_version_absent

Gazelle's output when no language version is derivable: no
`# gazelle:dart_language_version` directive and no pubspec.yaml. The package's
`dart_package_metadata` states none, so the package has the SDK's own. The
package is at the repository's root, which gives no name, and has a codegen
target, so the metadata states the library's name, `lib`, for the library
and the codegen target alike.
