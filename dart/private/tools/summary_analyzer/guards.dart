// Where the stock analyzer answers differently from a dependency's summary
// than from its source, and so must refuse rather than pass.
//
// A summary leaves out a library's "informative" data: offsets, names'
// positions, doc comments. The analyzer reads them from source alone, and a
// few of its checks give up, silently, without them. Each guard here detects
// the case one of those checks gives up on, from data a summary does hold.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/instrumentation/noop_service.dart';
import 'package:analyzer/instrumentation/plugin_data.dart';
import 'package:analyzer/instrumentation/service.dart';
import 'package:analyzer/utilities/extensions/uri.dart';
import 'package:path/path.dart' as p;

import 'report.dart';

/// Records the exceptions the analyzer catches and goes on from.
///
/// The analyzer logs, and otherwise ignores, an exception thrown while a lint
/// rule visits a node, and a few others: the rule's diagnostics for the rest
/// of the library are lost without a word. Reading a dependency from a
/// summary is the likeliest cause, and any of them makes the answer
/// incomplete.
class ExceptionRecorder extends NoopInstrumentationService {
  final refusals = <String>[];

  @override
  void logException(
    Object exception, [
    StackTrace? stackTrace,
    List<InstrumentationServiceAttachment>? attachments,
  ]) {
    refusals.add(
      'The analyzer caught an exception and went on, so some diagnostics may '
      'be missing: $exception'
      '${stackTrace == null ? '' : '\n${_head(stackTrace)}'}',
    );
  }

  @override
  void logPluginException(
    PluginData plugin,
    Object exception,
    StackTrace? stackTrace,
  ) => logException(exception, stackTrace);
}

String _head(StackTrace stack) =>
    stack.toString().split('\n').take(8).join('\n');

/// Whether [library] was read from a summary rather than from its source.
bool fromSummary(LibraryElement library) =>
    !p.isAbsolute(library.firstFragment.source.fullName);

/// The diagnostics [libraries] (paths of the defining files of the libraries
/// analyzed) would have, from source, that the analyzer does not give from
/// summaries, and the ones it gives that it would not; each refuses.
Future<List<String>> summaryLosses(
  AnalysisContext context,
  List<String> libraries,
  List<Reported> diagnostics,
) async {
  final session = context.currentSession;
  final refusals = <String>[];
  for (final path in libraries) {
    final result = await session.getLibraryByUri(
      '${session.uriConverter.pathToUri(path) ?? Uri.file(path)}',
    );
    if (result is! LibraryElementResult) continue;
    final library = result.element;
    refusals.addAll(lostClassModifierErrors(library));
    refusals.addAll(lostRelativeImports(context, path, library));
    refusals.addAll(
      await falseCommentReferences(session, library, diagnostics),
    );
  }
  return refusals;
}

// --- base/final/sealed -------------------------------------------------------
//
// `BaseOrFinalTypeVerifier._reportRestrictionError` (pkg/analyzer) reports
// nothing when the explicitly `base` or `final` type a class inherits that
// modifier from has no name offset, which a type from a summary never has: it
// cannot point its context message at the declaration. Below is the same
// decision, made on the element model a summary keeps, once as the analyzer
// makes it and once as it would with offsets. A class for which the second
// reports and the first does not has lost its error.

/// The class-modifier errors the analyzer drops in [library].
List<String> lostClassModifierErrors(LibraryElement library) {
  final lost = <String>[];
  final declared = <InterfaceElement>[...library.classes, ...library.mixins];
  for (final element in declared) {
    final actual = _ModifierCheck(library, withOffsets: false).check(element);
    if (actual != null) continue;
    final ideal = _ModifierCheck(library, withOffsets: true).check(element);
    if (ideal == null) continue;
    lost.add(
      '${_where(element)}: ${ideal.message} - ${ideal.code}\n'
      '  The analyzer reports this from source, but not when the supertype '
      "comes from a dependency's summary (Dart SDK bug: the check needs that "
      "type's source position).",
    );
  }
  return lost;
}

String _where(Element element) {
  final fragment = element.firstFragment;
  final source = fragment.libraryFragment?.source.fullName ?? '?';
  final offset = fragment.nameOffset;
  if (offset == null) return source;
  final line = fragment.libraryFragment!.lineInfo.getLocation(offset);
  return '$source:${line.lineNumber}:${line.columnNumber}';
}

/// An error the analyzer drops: its code and message, as it reports them.
typedef _Lost = ({String code, String message});

/// One run of the analyzer's class-modifier decision for [_library].
class _ModifierCheck {
  _ModifierCheck(this._library, {required this.withOffsets});

  final LibraryElement _library;

  /// Whether the check goes on where the analyzer, lacking an offset, stops.
  final bool withOffsets;

  bool _enabled(LibraryElement l) =>
      l.featureSet.isEnabled(Feature.class_modifiers);

  /// The first error the analyzer reports for [element], or null.
  _Lost? check(InterfaceElement element) {
    final supertype = element.supertype;
    if (supertype != null) {
      final r = _supertypes([supertype], element);
      if (r != null) return r;
    }
    final r = _supertypes(element.interfaces, element, implements: true);
    if (r != null) return r;
    final m = _supertypes(element.mixins, element);
    if (m != null) return m;
    if (element is MixinElement) {
      return _supertypes(element.superclassConstraints, element);
    }
    return null;
  }

  _Lost? _supertypes(
    List<InterfaceType> types,
    InterfaceElement sub, {
    bool implements = false,
  }) {
    for (final t in types) {
      final r = _restriction(sub, t.element, implements: implements);
      if (r != null) return r;
    }
    return null;
  }

  _Lost? _restriction(
    InterfaceElement element,
    InterfaceElement superElement, {
    required bool implements,
  }) {
    if (element.library != _library) return null;
    final InterfaceElement? baseOrFinal;
    if (_isBase(superElement) ||
        _isFinal(superElement) ||
        (!_enabled(superElement.library) && _enabled(element.library))) {
      baseOrFinal = _explicit(superElement);
    } else {
      return null;
    }
    if (baseOrFinal == null) return null;
    if (_mayIgnore(baseOrFinal.library)) return null;
    final fragment = baseOrFinal.firstFragment;
    if (!withOffsets &&
        (fragment.name == null || fragment.nameOffset == null)) {
      return null;
    }
    if (implements &&
        _isSealed(superElement) &&
        baseOrFinal.library != element.library &&
        _isBase(baseOrFinal)) {
      final kind = baseOrFinal is MixinElement ? 'mixin' : 'class';
      return (
        code: 'invalid_use_of_type_outside_library',
        message:
            "The $kind '${baseOrFinal.displayName}' can't be implemented "
            "outside of its library because it's a base $kind.",
      );
    }
    if (!_isBase(element) && !_isFinal(element) && !_isSealed(element)) {
      if (_isFinal(baseOrFinal)) {
        if (baseOrFinal.library != element.library &&
            (_enabled(superElement.library) ||
                !baseOrFinal.library.isInSdk ||
                implements)) {
          return null;
        }
        return _subtype(element, baseOrFinal, 'final');
      }
      if (_isBase(baseOrFinal)) {
        return _subtype(element, baseOrFinal, 'base');
      }
    }
    return null;
  }

  _Lost _subtype(InterfaceElement sub, InterfaceElement sup, String modifier) =>
      (
        code: 'subtype_of_base_or_final_is_not_base_final_or_sealed',
        message: sub is MixinElement
            ? "The mixin '${sub.displayName}' must be 'base' because the "
                  "supertype '${sup.displayName}' is '$modifier'."
            : "The type '${sub.displayName}' must be 'base', 'final' or "
                  "'sealed' because the supertype '${sup.displayName}' is "
                  "'$modifier'.",
      );

  bool _mayIgnore(LibraryElement superLibrary) {
    if (!superLibrary.isInSdk) return false;
    if (_library.isInSdk) return true;
    return !_enabled(_library);
  }

  InterfaceElement? _explicit(InterfaceElement element) {
    if ((_isBase(element) || _isFinal(element)) && !_isSealed(element)) {
      return element;
    }
    final supertype = element.supertype;
    return (supertype == null ? null : _explicitIn([supertype])) ??
        _explicitIn(element.interfaces) ??
        _explicitIn(element.mixins) ??
        (element is MixinElement
            ? _explicitIn(element.superclassConstraints)
            : null);
  }

  InterfaceElement? _explicitIn(List<InterfaceType> types) {
    for (final t in types) {
      final found = _explicit(t.element);
      if (found != null) return found;
    }
    return null;
  }
}

bool _isBase(InterfaceElement e) => switch (e) {
  ClassElement() => e.isBase,
  MixinElement() => e.isBase,
  _ => false,
};

bool _isFinal(InterfaceElement e) => e is ClassElement && e.isFinal;

bool _isSealed(InterfaceElement e) => e is ClassElement && e.isSealed;

// --- prefer_relative_imports -------------------------------------------------
//
// The rule fires on a `package:` import of the importing library's own
// package from inside its `lib/` when the imported file is under the
// package's root. A library from a summary has no file, only its URI, so
// the rule never fires for one: a package split across targets loses it.

/// The `prefer_relative_imports` diagnostics the linter drops in [library],
/// defined at [path].
List<String> lostRelativeImports(
  AnalysisContext context,
  String path,
  LibraryElement library,
) {
  final options = context.getAnalysisOptionsForFile(
    context.currentSession.resourceProvider.getFile(path),
  );
  if (!options.lintRules.any((r) => r.name == 'prefer_relative_imports')) {
    return const [];
  }
  final package = context.contextRoot.workspace.findPackageFor(path);
  if (package == null) return const [];
  final libDir = p.join(package.root.path, 'lib');
  if (!p.isWithin(libDir, path)) return const [];
  final lost = <String>[];
  for (final fragment in library.fragments) {
    for (final import in fragment.libraryImports) {
      final imported = import.importedLibrary;
      final uri = import.uri;
      if (imported == null || uri is! DirectiveUriWithRelativeUri) continue;
      final relative = uri.relativeUri;
      if (!relative.isScheme('package') ||
          !relative.isSamePackageAs(library.uri) ||
          !fromSummary(imported)) {
        continue;
      }
      final line = fragment.lineInfo.getLocation(import.importKeywordOffset);
      lost.add(
        '${fragment.source.fullName}:${line.lineNumber}:${line.columnNumber}: '
        "the linter does not report `prefer_relative_imports` for '$relative', "
        'a library of the same package in another target, which it reads from '
        'a summary (Dart SDK bug: the rule needs the file\'s path).',
      );
    }
  }
  return lost;
}

// --- comment_references ------------------------------------------------------
//
// The analyzer resolves a doc comment's references against the libraries its
// `@docImport`s name only when they come from source (`LibraryAnalyzer`
// keeps `LibraryImportWithFile` alone). A name a doc import of a summary
// library brings in is reported as not in scope.

/// The `comment_references` diagnostics in [library] that are false: each
/// names something a doc import read from a summary provides.
Future<List<String>> falseCommentReferences(
  AnalysisSession session,
  LibraryElement library,
  List<Reported> diagnostics,
) async {
  final units = {for (final f in library.fragments) f.source.fullName};
  final reported = [
    for (final d in diagnostics)
      if (d.code == 'comment_references' && units.contains(d.file)) d,
  ];
  if (reported.isEmpty) return const [];

  // What the doc imports read from summaries make visible, by prefix (''
  // for none).
  final visible = <String, List<LibraryElement>>{};
  final names = <String, String>{};
  for (final unitPath in units) {
    final parsed = session.getParsedUnit(unitPath);
    if (parsed is! ParsedUnitResult) continue;
    final collector = _DocImports();
    parsed.unit.accept(collector);
    for (final directive in collector.imports) {
      final text = directive.uri.stringValue;
      if (text == null) continue;
      final uri = library.uri.resolve(text);
      final result = await session.getLibraryByUri('$uri');
      if (result is! LibraryElementResult || !fromSummary(result.element)) {
        continue;
      }
      final prefix = directive.prefix?.name ?? '';
      visible.putIfAbsent(prefix, () => []).add(result.element);
      names[prefix] = text;
    }
  }
  if (visible.isEmpty) return const [];

  final falsePositives = <String>[];
  for (final d in reported) {
    final content = File(d.file).readAsStringSync();
    if (d.offset + d.length > content.length) continue;
    final reference = content.substring(d.offset, d.offset + d.length);
    final parts = reference.split('.');
    String? from;
    if (parts.length > 1 && visible.containsKey(parts.first)) {
      from = names[parts.first];
    } else {
      for (final l in visible[''] ?? const <LibraryElement>[]) {
        if (l.exportNamespace.get2(parts.first) != null) {
          from = l.uri.toString();
          break;
        }
      }
    }
    if (from == null) continue;
    falsePositives.add(
      '${d.file}:${d.line}:${d.column}: this `comment_references` is false: '
      "'$reference' comes from the doc import of '$from', which the analyzer "
      'ignores when that library is read from a summary (Dart SDK bug).',
    );
  }
  return falsePositives;
}

class _DocImports extends RecursiveAstVisitor<void> {
  final imports = <ImportDirective>[];

  @override
  void visitComment(Comment node) {
    for (final d in node.docImports) {
      imports.add(d.import);
    }
    super.visitComment(node);
  }
}
