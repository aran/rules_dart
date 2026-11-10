# dart_build_yaml_refused

Generation fails, naming each part of a codegen package's `build.yaml` that no
codegen target's `config` can carry: another target, `generate_for`,
`global_options`, a builder Gazelle does not run, a `build.<name>.yaml`
(`refused/`), and options a `# gazelle:dart_builder_config` directive states
differently (`disagreeing/`). A package with no codegen has its `build.yaml`
left unread (`plain/`), as does one that excludes it (`excluded/`).
