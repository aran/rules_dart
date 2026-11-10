Update-style fixture for `dart_test` tags. Gazelle manages `tags` from the
file's package:test `@Tags`: a tag dropped from `@Tags` leaves the target, a
hand-written tag survives only with `# keep` (Gazelle's rule for every
attribute it manages), and each tag the merge removes is logged so a
hand-written one is not lost silently.
