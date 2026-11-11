# dart_build_yaml_refused

Generation fails, naming by key path and line each part of a codegen
package's `build.yaml` that no codegen target's `config` can carry and no
`# gazelle:dart_build_yaml_ignore` names: `generate_for`, `global_options`,
a builder Gazelle does not run; and a `build.<name>.yaml` (`refused/`), and
options a `# gazelle:dart_builder_config` directive states differently
(`disagreeing/`). A package with no codegen and no ignores has its
`build.yaml` left unread (`plain/`), as does one that excludes it
(`excluded/`).

An ignore that names no part Gazelle cannot carry fails too: one stated twice
or naming a part Gazelle carries (`stale/`), one beside an excluded
`build.yaml` (`excluded_ignored/`) or beside none (`noyaml/`). A package with
no codegen that states ignores has its `build.yaml` read only to check them
(`unread/`).

Options for a builder the package's sources do not use fail too
(`unused/`): no `config` would carry them.
