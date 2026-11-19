// What analysis does not report about a doc import it cannot resolve, the same
// whichever analyzer ran.
//
// A `@docImport` is written against everything its package can see, and often
// names what depends on its library. A target's analysis sees only the target's
// dependencies, and no edge can bring the rest in, as one pointing up the graph
// would be a cycle. So an unresolved doc import says nothing about the code,
// unless it names a file of a fetched package, which comes whole. A package
// built here may have more targets than this one reaches, so a file missing
// from it, or from a relative path, may still exist. Which `dart:` libraries
// exist depends on the platform, and a package can document a Flutter type, so
// one this SDK lacks (`dart:ui`) may exist too.
//
// A library analysis cannot see may declare any public name, so a reference to
// one is not reported while such a doc import could bring it in. Nothing shows
// more than that: this file reads diagnostics and source text, for each
// analyzer alike, and text cannot say what a name in scope resolves to. What is
// certain is reported: no import brings in a private name, and a doc import of
// a fetched package's missing file, itself reported, brings in nothing.
import 'dart:io';

const _unresolvedDocImport = 'uri_does_not_exist_in_doc_import';
const _commentReferences = 'comment_references';

/// Written into the staged project by `stage_config_project`: the packages it
/// holds whole, one per line.
const _fetchedPackages = 'fetched_packages.txt';

final _partOf = RegExp(
  r'''^\s*part\s+of\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

// The message says "doesn't", so a quoted URI is told by holding no space.
final _quoted = RegExp(r"'([^'\s]*)'");

final _commentMarker = RegExp(r'^\s*(///|/\*\*|\*+/?)', multiLine: true);

final _docImport = RegExp(
  r'''@docImport\s+(['"])(.*?)\1([^;]*);''',
  dotAll: true,
);

final _referenceCharacter = RegExp(r'[\w$.]');

/// [diagnostics] without what an unresolved doc import outside the target's
/// view explains: the doc import itself, and each `comment_references` it could
/// have supplied, in its library or a part of it.
///
/// [project] is the analyzed project. Each diagnostic has a [code], the path of
/// its [file], a [message], and the 1-based [line] and [column] it starts at.
List<T> withoutUnresolvedDocImports<T>(
  List<T> diagnostics, {
  required String project,
  required String Function(T) code,
  required String Function(T) file,
  required String Function(T) message,
  required int? Function(T) line,
  required int? Function(T) column,
}) {
  if (!diagnostics.any((d) => code(d) == _unresolvedDocImport)) {
    return diagnostics;
  }
  final fetched = _readFetchedPackages(project);
  final unresolved = <String, List<_DocImport>>{};
  for (final d in diagnostics) {
    if (code(d) != _unresolvedDocImport) continue;
    final uri = _uriOf(message(d));
    if (_inView(uri, fetched)) continue;
    final library = _normal(file(d));
    unresolved.putIfAbsent(library, () => []).add(_docImportOf(library, uri));
  }
  return [
    for (final d in diagnostics)
      if (switch (code(d)) {
        _unresolvedDocImport => _inView(_uriOf(message(d)), fetched),
        _commentReferences => !_couldSupply(
          unresolved,
          _normal(file(d)),
          line(d),
          column(d),
        ),
        _ => true,
      })
        d,
  ];
}

String _normal(String path) => File(path).absolute.uri.toFilePath();

/// The URI an unresolved doc import's [message] quotes.
String? _uriOf(String message) => _quoted.firstMatch(message)?[1];

Set<String> _readFetchedPackages(String project) {
  try {
    return File('$project/$_fetchedPackages')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty)
        .toSet();
  } on FileSystemException {
    return const {};
  }
}

/// Whether [uri] names a file of a package analysis holds whole, so that its
/// not resolving means it does not exist.
bool _inView(String? uri, Set<String> fetched) {
  final parsed = uri == null ? null : Uri.tryParse(uri);
  return parsed != null &&
      parsed.isScheme('package') &&
      parsed.pathSegments.isNotEmpty &&
      fetched.contains(parsed.pathSegments.first);
}

/// Whether a doc import unresolved in the library of the file at [path] could
/// bring in the name referred to at [line] and [column].
bool _couldSupply(
  Map<String, List<_DocImport>> unresolved,
  String path,
  int? line,
  int? column,
) {
  final imports = _importsOfLibrary(unresolved, path);
  if (imports == null) return false;
  final reference = _referenceAt(path, line, column);
  return reference == null || imports.any((i) => i.couldSupply(reference));
}

/// The unresolved doc imports of the file at [path], or of the library it is a
/// part of.
List<_DocImport>? _importsOfLibrary(
  Map<String, List<_DocImport>> unresolved,
  String path,
) {
  final seen = <String>{};
  String? current = path;
  while (current != null && seen.add(current)) {
    final imports = unresolved[current];
    if (imports != null) return imports;
    current = _libraryOfPart(current);
  }
  return null;
}

String? _read(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// The file the part at [path] says it belongs to, or null when it is no part
/// or names its library rather than a file.
String? _libraryOfPart(String path) {
  final text = _read(path);
  if (text == null) return null;
  final uri = _partOf.firstMatch(text)?[1];
  return uri == null ? null : File(path).uri.resolve(uri).toFilePath();
}

/// The dotted name in the file at [path] around [line] and [column], or null
/// when it cannot be read.
String? _referenceAt(String path, int? line, int? column) {
  final lines = _read(path)?.split('\n');
  if (lines == null || line == null || column == null) return null;
  if (line < 1 || line > lines.length) return null;
  final text = lines[line - 1];
  bool inName(int i) =>
      i >= 0 && i < text.length && _referenceCharacter.hasMatch(text[i]);
  var start = column - 1;
  if (!inName(start)) return null;
  var end = start;
  while (inName(start - 1)) {
    start--;
  }
  while (inName(end + 1)) {
    end++;
  }
  return text.substring(start, end + 1);
}

/// How the library at [path] writes its doc import of [uri]. One that cannot be
/// found could bring in anything.
_DocImport _docImportOf(String path, String? uri) {
  final text = _read(path)?.replaceAll(_commentMarker, '') ?? '';
  for (final match in _docImport.allMatches(text)) {
    if (match[2] == uri) return _DocImport.parse(match[3]!);
  }
  return const _DocImport();
}

/// The names a doc import brings into scope.
class _DocImport {
  const _DocImport({this.prefix, this.shown, this.hidden = const {}});

  /// Reads what follows the URI: `as p`, `show A, B`, `hide C`.
  factory _DocImport.parse(String clauses) {
    String? prefix;
    Set<String>? shown;
    final hidden = <String>{};
    Set<String>? names;
    final words = clauses.split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty);
    final iterator = words.iterator;
    while (iterator.moveNext()) {
      switch (iterator.current) {
        case 'as':
          if (iterator.moveNext()) prefix = iterator.current;
        case 'show':
          names = shown = {...?shown};
        case 'hide':
          names = hidden;
        case final name:
          names?.add(name);
      }
    }
    return _DocImport(prefix: prefix, shown: shown, hidden: hidden);
  }

  final String? prefix;
  final Set<String>? shown;
  final Set<String> hidden;

  /// Whether `[reference]` could mean something this doc import brings in. Its
  /// first name is what the import must supply; what follows may be a member.
  /// An import brings in no private name.
  bool couldSupply(String reference) {
    var names = reference.split('.');
    if (prefix != null) {
      if (names.first != prefix || names.length < 2) return false;
      names = names.sublist(1);
    }
    final name = names.first;
    return !name.startsWith('_') &&
        (shown?.contains(name) ?? true) &&
        !hidden.contains(name);
  }
}
