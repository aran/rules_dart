/// Bazel persistent worker for Dart code generation.
///
/// Amortizes Dart analyzer / VM startup across multiple dart_codegen actions
/// by staying alive between requests and running generator scripts in-process
/// via [Isolate.spawnUri].
///
/// Speaks the Bazel JSON worker protocol:
///   - Reads newline-delimited JSON from stdin:
///       {"arguments": [...], "requestId": 0}
///   - Writes newline-delimited JSON to stdout:
///       {"exitCode": 0, "output": "...", "requestId": 0}
///
/// Use with `--worker_protocol=json` in the Bazel action configuration.
///
/// Arguments forwarded to the generator (per work request):
///   --generator <path>   Path to the generator .dart script
///   --input <path>       Input file path
///   --output <path>      Output file path
///   (remaining args)     Passed through as generator_args
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

// ---------------------------------------------------------------------------
// JSON worker protocol types
// ---------------------------------------------------------------------------

/// A single work request from Bazel.
final class WorkRequest {
  WorkRequest({required this.arguments, required this.requestId});

  factory WorkRequest.fromJson(Map<String, dynamic> json) {
    return WorkRequest(
      arguments: (json['arguments'] as List<dynamic>).cast<String>(),
      requestId: (json['requestId'] as num?)?.toInt() ?? 0,
    );
  }

  final List<String> arguments;
  final int requestId;
}

/// A work response sent back to Bazel.
final class WorkResponse {
  WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Map<String, dynamic> toJson() => {
        'exitCode': exitCode,
        'output': output,
        'requestId': requestId,
      };
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

/// Parsed arguments for a single codegen invocation.
final class CodegenArgs {
  CodegenArgs({
    required this.generator,
    required this.generatorArgs,
  });

  /// Path to the generator .dart script.
  final String generator;

  /// All arguments forwarded to the generator (including --input, --output).
  final List<String> generatorArgs;
}

/// Parses worker request arguments into [CodegenArgs].
///
/// Extracts `--generator <path>` and passes everything else through to the
/// generator script unchanged.
CodegenArgs parseArgs(List<String> args) {
  String? generator;
  final generatorArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--generator' && i + 1 < args.length) {
      generator = args[++i];
    } else {
      generatorArgs.add(args[i]);
    }
  }

  if (generator == null) {
    throw ArgumentError('Missing required --generator argument');
  }

  return CodegenArgs(generator: generator, generatorArgs: generatorArgs);
}

// ---------------------------------------------------------------------------
// Isolate-based generator execution
// ---------------------------------------------------------------------------

/// Runs a generator .dart script in an isolate, capturing its stdout/stderr.
///
/// Returns a [WorkResponse] with exit_code 0 on success, 1 on failure.
Future<WorkResponse> runGenerator(
  CodegenArgs args, {
  required int requestId,
}) async {
  final output = StringBuffer();

  try {
    // Ports for capturing the isolate's print() / stdout output and errors.
    final outputPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    final generatorUri = Uri.file(File(args.generator).absolute.path);

    // Resolve package config from the generator's directory or the current
    // working directory. This replaces the deprecated automaticPackageResolution.
    final generatorDir = File(args.generator).absolute.parent;
    var packageConfigUri = generatorDir.uri.resolve('.dart_tool/package_config.json');
    if (!File.fromUri(packageConfigUri).existsSync()) {
      packageConfigUri = Uri.file('${Directory.current.path}/.dart_tool/package_config.json');
    }

    final isolate = await Isolate.spawnUri(
      generatorUri,
      args.generatorArgs,
      null, // message — unused; generators read args from their main()
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
      packageConfig: File.fromUri(packageConfigUri).existsSync() ? packageConfigUri : null,
      errorsAreFatal: true,
    );

    // Collect errors.
    var hadError = false;
    final errorSub = errorPort.listen((error) {
      hadError = true;
      // Errors arrive as [errorString, stackTraceString].
      if (error is List) {
        output.writeln(error[0]);
        if (error.length > 1 && error[1] != null) {
          output.writeln(error[1]);
        }
      } else {
        output.writeln(error);
      }
    });

    // Wait for the isolate to exit.
    await exitPort.first;

    // Clean up.
    errorSub.cancel();
    outputPort.close();
    errorPort.close();
    exitPort.close();

    return WorkResponse(
      exitCode: hadError ? 1 : 0,
      output: output.toString(),
      requestId: requestId,
    );
  } catch (e, st) {
    output.writeln('codegen_worker: failed to run generator');
    output.writeln(e);
    output.writeln(st);
    return WorkResponse(exitCode: 1, output: output.toString(), requestId: requestId);
  }
}

// ---------------------------------------------------------------------------
// Worker loop
// ---------------------------------------------------------------------------

/// Entry point. In persistent worker mode (--persistent_worker), enters the
/// request loop. Otherwise executes a single request from the command-line
/// arguments (useful for non-worker fallback).
Future<void> main(List<String> args) async {
  if (args.contains('--persistent_worker')) {
    await _runWorkerLoop();
  } else {
    // One-shot mode: run a single request from command-line args.
    await _runOneShot(args);
  }
}

/// Reads JSON work requests from stdin, processes them, and writes JSON
/// work responses to stdout. Runs until stdin is closed.
Future<void> _runWorkerLoop() async {
  // Signal readiness by flushing stdout (Bazel expects it).
  await stdout.flush();

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;

    WorkRequest request;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      request = WorkRequest.fromJson(json);
    } catch (e) {
      // Malformed request — write an error response with requestId 0.
      final response = WorkResponse(
        exitCode: 1,
        output: 'codegen_worker: malformed work request: $e',
        requestId: 0,
      );
      stdout.writeln(jsonEncode(response.toJson()));
      await stdout.flush();
      continue;
    }

    final response = await _processRequest(request);
    stdout.writeln(jsonEncode(response.toJson()));
    await stdout.flush();
  }
}

/// Processes a single [WorkRequest] and returns a [WorkResponse].
Future<WorkResponse> _processRequest(WorkRequest request) async {
  try {
    final codegenArgs = parseArgs(request.arguments);
    return await runGenerator(codegenArgs, requestId: request.requestId);
  } on ArgumentError catch (e) {
    return WorkResponse(
      exitCode: 1,
      output: 'codegen_worker: $e',
      requestId: request.requestId,
    );
  } catch (e, st) {
    return WorkResponse(
      exitCode: 1,
      output: 'codegen_worker: unexpected error: $e\n$st',
      requestId: request.requestId,
    );
  }
}

/// One-shot mode: parse args directly, run generator, exit.
Future<void> _runOneShot(List<String> args) async {
  final request = WorkRequest(arguments: args, requestId: 0);
  final response = await _processRequest(request);

  if (response.output.isNotEmpty) {
    stderr.write(response.output);
  }
  exit(response.exitCode);
}
