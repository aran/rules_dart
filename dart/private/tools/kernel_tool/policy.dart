// The rules Bazel adds to the compiler's: what a target may import. They are
// BUILD-file hygiene, checked over every library of the target before it is
// compiled, not only those a program reaches.
import 'module_graph.dart';
import 'uris.dart';

class Violation {
  const Violation(this.library, this.message);

  /// The library whose imports break the rule.
  final String library;

  /// A full sentence, starting with the target's label.
  final String message;
}

/// Imports that break a rule, in library order.
///
/// - strict deps: a package that neither [availablePackages] nor the package
///   config names;
/// - a file of the target's own package that nothing compiles: the target is
///   one of several that split a package, and lacks the one holding the file.
///   [provided] says whether some module holds a file;
/// - layering, with [checkLayering]: a package only a dependency's
///   dependencies provide.
List<Violation> checkPolicy({
  required String label,
  required Map<String, LibraryNode> libraries,
  required Set<String> partFiles,
  required PackageConfig config,
  required Set<String> availablePackages,
  required bool Function(String uri) provided,
  bool checkLayering = false,
  Set<String> directPackages = const {},
  String? ownPackage,
}) {
  // Unstated (an executable's own files), the packages its files sit in.
  final ownPackages = ownPackage != null
      ? {ownPackage}
      : {
          for (final uri in [...libraries.keys, ...partFiles])
            ?config.packageOf(uri),
        };

  bool unprovided(String uri) =>
      ownPackages.contains(config.packageOf(uri)) &&
      !libraries.containsKey(uri) &&
      !partFiles.contains(uri) &&
      !provided(uri);

  final violations = <Violation>[];
  for (final uri in libraries.keys.toList()..sort()) {
    final lib = libraries[uri]!;
    final reported = <String>{};
    void add(String message) => violations.add(Violation(uri, message));
    for (final import in lib.imports) {
      if (import.selected case final selected? when unprovided(selected)) {
        if (reported.add(selected)) {
          add(
            '$label: ${lib.path} imports $selected, a file of its own '
            'package that neither $label nor any of its deps compiles. Add '
            'the target that holds it to deps.',
          );
        }
        continue;
      }
      final imported = import.selected ?? import.defaultUri;
      final name = packageNameOf(imported);
      if (name == null || !reported.add(imported)) continue;
      if (!availablePackages.contains(name) && !config.names.contains(name)) {
        add(
          '$label: ${lib.path} imports $imported, but no dependency of '
          '$label provides package "$name". Add the target that provides it '
          'to deps.',
        );
      } else if (checkLayering &&
          availablePackages.contains(name) &&
          name != ownPackage &&
          !config.names.contains(name) &&
          !directPackages.contains(name)) {
        add(
          '$label: ${lib.path} imports $imported, but package "$name" is not '
          'a direct dependency of $label, only of something it depends on. '
          'Add the target that provides it to deps.',
        );
      }
    }
  }
  return violations;
}
