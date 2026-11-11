# dart_cycle_stale

A directive declares `ping` and `pong` a cycle, but `pong` no longer imports
`ping`. Gazelle fails, naming the directive and what to change, and writes
nothing.
