/// The library half of the fixture. The entrypoint imports it by `package:`
/// URI, so an analyze run that staged the entrypoint without its closure would
/// fail on an unresolved import rather than pass vacuously.
String greeting() => 'hello';
