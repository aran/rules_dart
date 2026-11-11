# dart_cycle

`ping` and `pong` import each other, and `pp/BUILD.bazel` declares them a
cycle. Each package's root gets a `dart_package_member` and an `alias` named
like its library; `pp` gets the `dart_package_cycle`, which depends on what the
members import from outside it. Imports of either package, from a test of
`ping` and from the root's `app`, resolve to the cycle.
