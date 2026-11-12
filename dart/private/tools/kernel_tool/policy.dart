// The rules Bazel adds to the compiler's: what a target's files may name. They
// are BUILD-file hygiene, checked over every file of the target whether or not
// a program reaches it, and over every branch of a conditional import: a
// library has to declare what each branch needs.
//
// Every `import`, `export` and `part` is judged as the compiler will spell it,
// not as our tooling canonicalises it. It must be a `dart:` library, a
// `package:` URI that stays inside its package and that a dependency provides,
// or a file the target (for a part) or the target or its dependencies (for an
// import) hold; the empty URI names the library itself. Anything else reaches a file Bazel does not track, or loads a
// second copy of a library under a URI its module does not know.
import 'directives.dart';
import 'uris.dart';

/// A file of the target and what it names.
class CheckedFile {
  const CheckedFile({
    required this.path,
    required this.rootPath,
    required this.uri,
    required this.directives,
  });

  /// The exec path, as shown in messages.
  final String path;

  /// The path relative to its kernel root.
  final String rootPath;

  /// The URI the compiler knows the file by: [PackageConfig.uriFor].
  final String uri;

  final Directives directives;
}

class Violation {
  const Violation(this.library, this.message);

  /// The file whose directive breaks the rule.
  final String library;

  /// A full sentence, starting with the target's label.
  final String message;
}

/// Directives that break a rule, in file order.
///
/// - spelling: a URI the compiler would read off the host (`file:`), from
///   outside every declared input (a relative path out of the workspace, a
///   `package:` URI climbing out of its package, any other scheme), or as a
///   second copy of a library (a relative path into a package's `lib/`, which
///   the compiler loads apart from its `package:` URI, or any URI with a query
///   or fragment);
/// - a part the target does not hold: a part compiles with its library;
/// - strict deps: a package that neither [availablePackages] nor the package
///   config names;
/// - a file nothing compiles: one that neither the target nor its
///   dependencies hold. [dependencyFiles] are the URIs of the dependencies'
///   files; a package addressed outside the kernel roots is not looked into;
/// - layering, with [checkLayering]: a package only a dependency's
///   dependencies provide, that is, not among [directPackages].
///
/// A library's import of a package no dependency provides suggests a
/// `dart_package_cycle` unless [suggestCycle] is false. With [checkParts]
/// false the files' parts are not judged: they are a generator's inputs, whose
/// parts it has yet to write.
List<Violation> checkPolicy({
  required String label,
  required List<CheckedFile> files,
  required PackageConfig config,
  required Set<String> availablePackages,
  required Set<String> dependencyFiles,
  bool checkLayering = false,
  Set<String> directPackages = const {},
  Set<String> ownPackages = const {},
  bool suggestCycle = true,
  bool checkParts = true,
}) {
  final held = {for (final f in files) f.uri};
  // Unstated (an executable's own files), the packages its files sit in.
  final own = ownPackages.isNotEmpty
      ? ownPackages
      : {for (final f in files) ?config.packageOf(f.uri)};

  final violations = <Violation>[];
  for (final f in [...files]..sort((a, b) => a.uri.compareTo(b.uri))) {
    final seen = <String>{};
    void judge(String verb, String written, {bool part = false}) {
      if (!seen.add('$verb $written')) return;
      void add(String message) =>
          violations.add(Violation(f.uri, '$label: ${f.path} $verb $message'));

      final judged = compiledUri(written, f, config, label);
      if (judged.refusal case final refusal?) {
        add("'$written', $refusal");
        return;
      }
      final uri = judged.uri!;
      final named = uri == written ? uri : "'$written' ($uri)";
      if (part) {
        if (!held.contains(uri)) {
          add(
            '$named, which $label does not hold. A part is compiled with the '
            'library that names it: add the file to srcs of $label.',
          );
        }
        return;
      }
      if (uri.startsWith('dart:')) return;
      final provided = held.contains(uri) || dependencyFiles.contains(uri);
      final name = packageNameOf(uri);
      if (name == null) {
        if (!provided) {
          add(
            '$named, a file that neither $label nor any of its deps holds. '
            'Add it to srcs of $label, or the target that holds it to deps.',
          );
        }
      } else if (own.contains(name)) {
        if (!provided) {
          add(
            '$named, a file of its own package that neither $label nor any '
            'of its deps compiles. Add the target that holds it to deps.',
          );
        }
      } else if (!availablePackages.contains(name) &&
          !config.names.contains(name)) {
        // A library's own package may be what that package imports in
        // turn, which Bazel cannot build as two targets. A cycle's own check
        // says so for a `dart_package_cycle` ([suggestCycle] false).
        final cycle = ownPackages.isEmpty || !suggestCycle
            ? ''
            : ' If package "$name" imports this one in turn, the two are a '
                  'dependency cycle: build them as one `dart_package_cycle`.';
        add(
          '$named, but no dependency of $label provides package "$name". Add '
          'the target that provides it to deps.$cycle',
        );
      } else if (checkLayering && !directPackages.contains(name)) {
        add(
          '$named, but package "$name" is not a direct dependency of $label, '
          'only of something it depends on. Add the target that provides it '
          'to deps.',
        );
      } else if (!provided && config.libDirOf(name) != null) {
        add(
          '$named, but no dependency of $label holds that file of package '
          '"$name". Check the path, or add the target that holds it to deps.',
        );
      }
    }

    for (final d in f.directives.directives) {
      final verb = d.isExport ? 'exports' : 'imports';
      judge(verb, d.uri);
      for (final c in d.configurations) {
        judge(verb, c.uri);
      }
    }
    if (checkParts) {
      for (final p in f.directives.parts) {
        judge('has the part', p, part: true);
      }
    }
  }
  return violations;
}

/// The URI the compiler loads for [written] in [file], or why it is refused.
({String? uri, String? refusal}) compiledUri(
  String written,
  CheckedFile file,
  PackageConfig config,
  String label,
) {
  ({String? uri, String? refusal}) ok(String uri) => (uri: uri, refusal: null);
  ({String? uri, String? refusal}) refuse(String why) =>
      (uri: null, refusal: why);

  final Uri ref;
  try {
    ref = Uri.parse(written);
  } on FormatException {
    return refuse('which is not a valid URI.');
  }
  if (ref.hasQuery || ref.hasFragment) {
    final bare = ref.removeFragment().replace(query: '').toString();
    final hint = bare.endsWith('?') ? bare.substring(0, bare.length - 1) : bare;
    return refuse(
      'a URI with a query or fragment: the compiler loads it as a library '
      "apart from the file's own URI, a second copy with its own state. "
      "${hint.isEmpty ? 'Write the URI without it.' : "Use '$hint' instead."}",
    );
  }
  final relativeHint = 'a path relative to ${file.path}';
  switch (ref.scheme) {
    case 'dart':
      return ok(written);
    case 'package':
      return _packageUri(written, ref);
    case rootScheme:
      final named = config.uriFor(ref.path.replaceFirst(RegExp('^/+'), ''));
      return refuse(
        'a URI internal to the build, not one to write in a source. '
        '${named.startsWith('package:') ? "Use '$named'" : 'Use $relativeHint'} '
        'instead.',
      );
    case 'file':
      return refuse(
        'a file: URI, which the compiler reads from wherever the machine has '
        'it, outside what the build declares. Name the file by a package: URI '
        'a dependency provides, or by $relativeHint, and declare the target '
        'that holds it.',
      );
    case '':
      break;
    default:
      return refuse(
        'a ${ref.scheme}: URI, which names nothing the build declares. Import '
        'a dart: library, a package: URI a dependency provides, or a file of '
        '$label.',
      );
  }
  // An empty reference is the library itself (ffigen writes
  // `import '' as self;`), as URI resolution makes it.
  if (written.isEmpty) return ok(file.uri);
  if (ref.hasAuthority || ref.path.startsWith('/')) {
    return refuse(
      'an absolute path, which names a file outside what the build declares. '
      'Use $relativeHint, or a package: URI.',
    );
  }
  // Where the path leads in the workspace, against where the compiler's URI
  // resolution takes it: the two part when the path climbs out of a
  // package's lib/ (a `package:` URI cannot leave its package), and a path
  // into a lib/ from outside names a library apart from its `package:` URI.
  final segments = file.rootPath.split('/')..removeLast();
  for (final segment in ref.pathSegments) {
    if (segment.contains('/') || segment.contains(r'\')) {
      return refuse(
        'whose path has an encoded separator. Write the path out with /.',
      );
    }
    if (segment == '..') {
      if (segments.isEmpty) {
        return refuse(
          'which climbs above the workspace. Name the file by a package: URI '
          'a dependency provides, or by $relativeHint inside the workspace.',
        );
      }
      segments.removeLast();
    } else if (segment != '.' && segment.isNotEmpty) {
      segments.add(segment);
    }
  }
  final path = segments.join('/');
  final named = config.uriFor(path);
  final compiled = Uri.parse(file.uri).resolveUri(ref).toString();
  if (_same(compiled, named)) return ok(named);
  if (file.uri.startsWith('package:')) {
    return refuse(
      'which climbs out of lib/ of package "${packageNameOf(file.uri)}": the '
      'compiler reads it as $compiled, not as $path. '
      '${named.startsWith('package:') ? "Use '$named' instead." : 'A file outside lib/ cannot be imported from inside it.'}',
    );
  }
  return refuse(
    'a path into lib/ of package "${packageNameOf(named)}": the compiler '
    'would load it as $compiled, a second copy of the library its dependency '
    "compiles as $named. Use '$named' instead.",
  );
}

/// A `package:` URI must stay inside the package it names: `..` and encoded
/// separators can climb out, and the compiler then reads another package's
/// file, or a file of no package.
({String? uri, String? refusal}) _packageUri(String written, Uri parsed) {
  final rest = written.substring('package:'.length);
  final slash = rest.indexOf('/');
  final name = slash < 0 ? rest : rest.substring(0, slash);
  final segments = parsed.pathSegments;
  final inside =
      name.isNotEmpty &&
      !parsed.path.startsWith('/') &&
      segments.length >= 2 &&
      segments.first == name &&
      segments.every(
        (s) => s.isNotEmpty && !s.contains('/') && !s.contains(r'\'),
      );
  if (!inside) {
    return (
      uri: null,
      refusal:
          'a package: URI that does not stay inside one package (the compiler '
          'reads it as $parsed). Name a file in lib/ of its package, as '
          'package:<package>/<path under lib/>.',
    );
  }
  return (uri: parsed.toString(), refusal: null);
}

bool _same(String a, String b) {
  String norm(String u) {
    try {
      return Uri.parse(u).toString();
    } on FormatException {
      return u;
    }
  }

  return a == b || norm(a) == norm(b);
}
