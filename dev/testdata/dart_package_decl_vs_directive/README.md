# dart_package_decl_vs_directive

A `# gazelle:dart_package_name` directive and a `dart_package` in the same
directory naming different packages. The declaration wins, which leaves the
directive as a value the developer stated and nothing acts on — so Gazelle says
so on stderr rather than resolving it quietly. Pinned here because a diagnostic
nobody asserts is a diagnostic that stops being emitted.
