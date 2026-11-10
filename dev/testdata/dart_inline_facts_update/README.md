# dart_inline_facts_update

A BUILD file from before package facts lived only on `dart_package_metadata`:
`package_name`, `language_version`, `build_hook` and `license_file` stated
inline on the library, the codegen macro and a binary. Gazelle writes the
package's metadata and names it with `package` on each, and removes the inline
attributes, which the rules no longer take. The library's hand-written
`code_assets` moves onto the metadata, which states none yet.
