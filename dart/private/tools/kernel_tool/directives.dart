// Reads the directives of a Dart file with `package:analyzer`'s parser, as
// `build_modules` does: the `import`, `export` and `part` lines, with each
// conditional import's branches, and whether the file is a `part of`.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart' as ast;

import 'uris.dart';

/// One `if (name) 'uri'` or `if (name == 'value') 'uri'` clause of a
/// conditional import or export.
class Configuration {
  const Configuration(this.name, this.value, this.uri);

  /// The dotted name under test, such as `dart.library.io`.
  final String name;

  /// What the name is compared with, or null for the bare `if (name)` form,
  /// which means `== 'true'`.
  final String? value;

  final String uri;
}

/// An `import` or `export` directive.
class UriDirective {
  const UriDirective(this.isExport, this.uri, this.configurations);

  final bool isExport;

  /// The unconditional URI, used when no configuration holds.
  final String uri;

  final List<Configuration> configurations;
}

class Directives {
  const Directives(this.directives, this.parts, this.isPart);

  /// Every `import` and `export`, in source order.
  final List<UriDirective> directives;

  /// The URIs of the `part` directives, as written.
  final List<String> parts;

  /// Whether the file is a `part of` another.
  final bool isPart;
}

/// Parses [text], tolerating syntax errors: a file that does not parse is a
/// compiler diagnostic, not this tool's.
Directives readDirectives(String path, String text) {
  final unit = parseString(
    content: text,
    path: path,
    throwIfDiagnostics: false,
  ).unit;
  final directives = <UriDirective>[];
  final parts = <String>[];
  var isPart = false;
  for (final directive in unit.directives) {
    switch (directive) {
      case ast.PartOfDirective():
        isPart = true;
      case ast.PartDirective():
        if (directive.uri.stringValue case final uri?) parts.add(uri);
      case ast.NamespaceDirective():
        final uri = directive.uri.stringValue;
        // A native extension is not Dart code.
        if (uri == null || uri.startsWith('dart-ext:')) continue;
        directives.add(
          UriDirective(directive is ast.ExportDirective, uri, [
            for (final c in directive.configurations)
              if (c.uri.stringValue case final target?)
                Configuration(c.name.toSource(), c.value?.stringValue, target),
          ]),
        );
      default:
    }
  }
  return Directives(directives, parts, isPart);
}

/// An `import` or `export` with its URIs resolved and, where it can be told,
/// its conditional choice made.
class ResolvedImport {
  const ResolvedImport(this.selected, this.defaultUri, this.candidates);

  /// The URI the directive resolves to, or null when a configuration tests
  /// something other than `dart.library.*` and so cannot be decided here.
  final String? selected;

  final String defaultUri;

  /// Every URI the directive can name.
  final List<String> candidates;

  /// The URIs this directive may pull in: the one it selects, or every
  /// candidate when it cannot be decided. `build_modules` does the same.
  List<String> get reached => selected == null ? candidates : [selected!];
}

/// Picks the URI of [directive] in a file at [base]. With [supported] null
/// every configuration is undecidable. Package-relative URIs come out in the
/// spelling [config] gives them.
ResolvedImport resolveImport(
  UriDirective directive,
  String base,
  Set<String>? supported, [
  PackageConfig? config,
]) {
  String resolve(String ref) {
    final uri = resolveUri(base, ref);
    return config == null ? uri : config.canonical(uri);
  }

  final defaultUri = resolve(directive.uri);
  final candidates = [
    defaultUri,
    for (final c in directive.configurations) resolve(c.uri),
  ];
  for (final c in directive.configurations) {
    final bool? holds = supported == null || !c.name.startsWith('dart.library.')
        ? null
        : (supported.contains(c.name.substring('dart.library.'.length))
                  ? 'true'
                  : 'false') ==
              (c.value ?? 'true');
    if (holds == null) return ResolvedImport(null, defaultUri, candidates);
    if (holds) return ResolvedImport(resolve(c.uri), defaultUri, candidates);
  }
  return ResolvedImport(defaultUri, defaultUri, candidates);
}
