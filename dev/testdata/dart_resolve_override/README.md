# dart_resolve_override

Fixture guarding the `# gazelle:resolve dart <package> <label>`
override. Resolve builds import specs from the bare package name (the
`foo` of `package:foo/...`), so the directive takes the bare package
form — here mapping `shelf` to `//third_party:shelf_custom` instead of
the default external-repo label.
