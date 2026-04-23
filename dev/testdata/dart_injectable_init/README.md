## dart_injectable_init

Fixture guarding the `@InjectableInit` directory-aggregate path in
`GenerateRules`. When any file in a directory carries
`@InjectableInit`, Gazelle must emit a single `injectable_library`
macro over every file in the directory (metadata stage + config stage
handled internally by the macro) rather than one codegen rule per
file. Every non-init file becomes part of the macro's `srcs`; every
file is marked "injectable-consumed" so the per-file loop below
doesn't also emit duplicates.
