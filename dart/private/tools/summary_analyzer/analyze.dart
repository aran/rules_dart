// `analyze`: what `dart analyze --fatal-infos <project>` reports, with every
// dependency read from its summary, and a refusal wherever summaries are known
// to change the answer.
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/error_processor.dart';
import 'package:analyzer/source/file_source.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/analysis_options/analysis_options_parser.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/manifest/manifest_validator.dart';
import 'package:analyzer/src/pubspec/pubspec_validator.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer/src/workspace/pub.dart';
import 'package:linter/src/rules.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'args.dart';
import 'context.dart';
import 'guards.dart';
import 'report.dart';

var _rulesRegistered = false;

/// Analyzes `--project`; writes `--stamp` when nothing is reported.
Future<Result> analyze(Args args) async {
  final project = args.one('project');
  final stamp = args.one('stamp');
  final fatalInfos = args.flag('fatal-infos');
  if (!_rulesRegistered) {
    registerLintRules();
    _rulesRegistered = true;
  }
  final exceptions = ExceptionRecorder();
  final previous = AnalysisEngine.instance.instrumentationService;
  AnalysisEngine.instance.instrumentationService = exceptions;
  final collection = newCollection(args);
  final diagnostics = <Reported>[];
  final refusals = <String>[];
  try {
    for (final context in collection.contexts) {
      await _analyzeContext(context, diagnostics, refusals);
    }
  } catch (e, stack) {
    refusals.add(crashed(e, stack));
  } finally {
    AnalysisEngine.instance.instrumentationService = previous;
    await collection.dispose();
  }
  refusals.addAll(exceptions.refusals);

  final src = p.join(project, 'src');
  final out = StringBuffer();
  final code = report(out, diagnostics, src, fatalInfos: fatalInfos);
  if (refusals.isNotEmpty) {
    out.writeln();
    for (final r in refusals) {
      out.writeln(r);
    }
    out.write(turnOff);
    return (exitCode: 4, output: unstage(out.toString(), src));
  }
  if (code != 0) return (exitCode: code, output: unstage(out.toString(), src));
  File(stamp).writeAsStringSync('analyzed\n');
  return (exitCode: 0, output: '');
}

Future<void> _analyzeContext(
  DriverBasedAnalysisContext context,
  List<Reported> diagnostics,
  List<String> refusals,
) async {
  final driver = context.driver;
  final rp = PhysicalResourceProvider.INSTANCE;
  final parseSession = AnalysisOptionsParseSession();
  final libraries = <String>[];
  for (final path in context.contextRoot.analyzedFiles().toList()..sort()) {
    if (file_paths.isAnalysisOptionsYaml(p.context, path)) {
      final package = context.contextRoot.workspace.findPackageFor(path);
      final r = parseSession.parse(
        sourceFactory: driver.sourceFactory,
        contextRoot: context.contextRoot.root,
        file: rp.getFile(path),
        sdkVersionConstraint: package is PubPackage
            ? package.sdkVersionConstraint
            : null,
      );
      final content = r.content;
      if (content != null) {
        convert(
          diagnostics,
          r.diagnostics,
          content.lineInfo,
          r.analysisOptions,
        );
      }
      final plugins = [
        ...r.analysisOptions.enabledLegacyPluginNames,
        for (final c in r.analysisOptions.pluginsOptions.configurations) c.name,
      ];
      if (plugins.isNotEmpty) {
        refusals.add(
          '$path enables analyzer plugins (${plugins.join(', ')}), which '
          'analysis against summaries cannot run.',
        );
      }
    } else if (file_paths.isAndroidManifestXml(p.context, path)) {
      final file = rp.getFile(path);
      final content = file.readAsStringSync();
      final options = driver.getAnalysisOptionsForFile(file);
      convert(
        diagnostics,
        ManifestValidator(FileSource(file))
            .validate(content, options.chromeOsManifestChecks),
        LineInfo.fromContent(content),
        options,
      );
    } else if (file_paths.isPubspecYaml(p.context, path)) {
      final file = rp.getFile(path);
      final content = file.readAsStringSync();
      var node = loadYamlNode(content, sourceUrl: file.toUri());
      if (node is! YamlMap) node = YamlMap();
      final options = driver.getAnalysisOptionsForFile(file);
      convert(
        diagnostics,
        validatePubspec(
          contents: node,
          source: FileSource(file),
          provider: rp,
          analysisOptions: options,
        ),
        LineInfo.fromContent(content),
        options,
      );
    } else if (file_paths.isDart(p.context, path)) {
      final result = await context.currentSession.getErrors(path);
      if (result is! ErrorsResult) {
        refusals.add('the analyzer gave no diagnostics for $path ($result).');
        continue;
      }
      final options = context.getAnalysisOptionsForFile(result.file);
      convert(
        diagnostics,
        result.diagnostics,
        result.lineInfo,
        options,
        result: result,
      );
      if (!result.isPart) libraries.add(path);
    }
  }
  final fixData = File(
    p.join(context.contextRoot.root.path, 'lib', file_paths.fixDataYaml),
  );
  if (fixData.existsSync()) {
    refusals.add(
      '${fixData.path}: data-driven fixes are validated by the analysis '
      'server alone, which cannot read summaries.',
    );
  }
  refusals.addAll(await summaryLosses(context, libraries, diagnostics));
}

/// What an analyzer crash leaves: no diagnostics for its library at all.
String crashed(Object e, StackTrace stack) =>
    'The analyzer crashed, so the library it was analyzing has no '
    'diagnostics: $e\n${stack.toString().split('\n').take(8).join('\n')}';

/// The severity a processor gives [d] under [options], or the code's own.
DiagnosticSeverity? severityOf(AnalysisOptions? options, Diagnostic d) {
  final processor = ErrorProcessor.getProcessor(options, d);
  if (processor != null) return processor.severity;
  return d.diagnosticCode.severity;
}

/// Adds [diagnostics] to [out] as `dart analyze` keeps them: processors
/// applied, ignored ones and TODOs dropped.
void convert(
  List<Reported> out,
  List<Diagnostic> diagnostics,
  LineInfo lineInfo,
  AnalysisOptions? options, {
  ErrorsResult? result,
}) {
  for (final d in diagnostics) {
    final severity = severityOf(options, d);
    if (severity == null) continue;
    final code = d.diagnosticCode;
    if (code.type == DiagnosticType.TODO &&
        severity == DiagnosticSeverity.INFO) {
      continue;
    }
    final loc = lineInfo.getLocation(d.offset);
    final context = <Context>[];
    for (final m in d.contextMessages) {
      LineInfo? li;
      if (result == null) {
        li = lineInfo;
      } else if (m.filePath == result.path) {
        li = result.lineInfo;
      } else {
        final fr = result.session.getFile(m.filePath);
        if (fr is FileResult) li = fr.lineInfo;
      }
      // The server drops a message it cannot place, as here.
      if (li == null || m.offset < 0) continue;
      final ml = li.getLocation(m.offset);
      context.add(
        Context(
          m.messageText(includeUrl: true),
          m.filePath,
          ml.lineNumber,
          ml.columnNumber,
        ),
      );
    }
    out.add(
      Reported(
        severity: severity,
        code: code.lowerCaseName,
        file: d.source.fullName,
        offset: d.offset,
        length: d.length,
        line: loc.lineNumber,
        column: loc.columnNumber,
        message: d.message,
        correction: d.correctionMessage,
        context: context,
      ),
    );
  }
}
