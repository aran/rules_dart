# dart_cycle_undeclared

`ping` and `pong` import each other and nothing declares them a cycle. Gazelle
fails, naming the packages, a path through them and the directive to add, and
writes nothing.
