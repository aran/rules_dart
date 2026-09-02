# dart_package_decl_update

A package already converted to `dart_package_metadata`, re-run through Gazelle. The
rules carry `package = ":pkg"` instead of inline `package_name` /
`language_version`, and the two spellings are mutually exclusive — a rule
carrying both fails at analysis. So Gazelle must not re-add the inline
attributes to rules that reference a declaration, or running it would break
exactly the packages that adopted the tidier form.
