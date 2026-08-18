/// A `lib/` source of the package the executable under test contributes.
///
/// Reached from the entrypoint as `package:analyzable_pkg/model.dart` — the
/// import that reports `uri_does_not_exist` when the closure carries no record
/// of the package its own sources belong to.
class Model {
  const Model(this.name);

  final String name;
}
