# dart_cycle_removed

`pong` no longer imports `ping`, and the directive is gone. Gazelle deletes the
members, the aliases and the cycle, and writes each package's `dart_library`
again.
