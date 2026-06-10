# dart_injectable_init_update

Update-style fixture guarding `init_src` merging on `injectable_library`.
When the `@InjectableInit` file moves (here: from `old_injection.dart` to
`injection.dart`), re-running Gazelle over the existing BUILD file must
rewrite the stale `init_src` attr to the newly detected init file —
requiring `init_src` to be a mergeable attr on injectable_library's
KindInfo.
