import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart' as fs;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'analyzer_summary.dart'
    show
        BoundedResourceProvider,
        SummaryByteCache,
        SummaryCachingResourceProvider;

/// Recording wrapper around [PhysicalResourceProvider.INSTANCE] to verify that
/// blocked ancestor probes never reach the underlying filesystem.
final class _RecordingResourceProvider implements fs.ResourceProvider {
  _RecordingResourceProvider(this._delegate);

  final fs.ResourceProvider _delegate;
  final List<String> checkedPaths = <String>[];

  @override
  p.Context get pathContext => _delegate.pathContext;

  @override
  fs.File getFile(String path) => _RecordingFile(this, _delegate.getFile(path));

  @override
  fs.Folder getFolder(String path) =>
      _RecordingFolder(this, _delegate.getFolder(path));

  @override
  fs.Link getLink(String path) => _delegate.getLink(path);

  @override
  fs.Resource getResource(String path) {
    final r = _delegate.getResource(path);
    if (r is fs.File) return _RecordingFile(this, r);
    if (r is fs.Folder) return _RecordingFolder(this, r);
    return r;
  }

  @override
  fs.Folder? getStateLocation(String pluginId) =>
      _delegate.getStateLocation(pluginId);
}

final class _RecordingFolder implements fs.Folder {
  const _RecordingFolder(this._provider, this._delegate);

  final _RecordingResourceProvider _provider;
  final fs.Folder _delegate;

  @override
  bool get exists {
    _provider.checkedPaths.add(p.normalize(p.absolute(_delegate.path)));
    return _delegate.exists;
  }

  @override
  bool get isRoot => _delegate.isRoot;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  String canonicalizePath(String path) => _delegate.canonicalizePath(path);

  @override
  bool contains(String path) => _delegate.contains(path);

  @override
  fs.Folder copyTo(fs.Folder parentFolder) =>
      _RecordingFolder(_provider, _delegate.copyTo(parentFolder));

  @override
  void create() => _delegate.create();

  @override
  void delete() => _delegate.delete();

  @override
  fs.Resource getChild(String relPath) =>
      _provider.getResource(_provider.pathContext.join(path, relPath));

  @override
  fs.File getChildAssumingFile(String relPath) => getFile(relPath);

  @override
  fs.Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  fs.File getFile(String relPath) =>
      _provider.getFile(_provider.pathContext.join(path, relPath));

  @override
  fs.Folder getFolder(String relPath) =>
      _provider.getFolder(_provider.pathContext.join(path, relPath));

  @override
  List<fs.Resource> getChildren() => _delegate.getChildren();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  fs.Resource resolveSymbolicLinksSync() =>
      _delegate.resolveSymbolicLinksSync();

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();
}

final class _RecordingFile implements fs.File {
  const _RecordingFile(this._provider, this._delegate);

  final _RecordingResourceProvider _provider;
  final fs.File _delegate;

  @override
  bool get exists {
    _provider.checkedPaths.add(p.normalize(p.absolute(_delegate.path)));
    return _delegate.exists;
  }

  @override
  int get lengthSync => _delegate.lengthSync;

  @override
  int get modificationStamp => _delegate.modificationStamp;

  @override
  fs.Folder get parent => _RecordingFolder(_provider, _delegate.parent);

  @override
  String get path => _delegate.path;

  @override
  fs.ResourceProvider get provider => _provider;

  @override
  String get shortName => _delegate.shortName;

  @override
  fs.File copyTo(fs.Folder parentFolder) =>
      _RecordingFile(_provider, _delegate.copyTo(parentFolder));

  @override
  void delete() => _delegate.delete();

  @override
  bool isOrContains(String path) => _delegate.isOrContains(path);

  @override
  Uint8List readAsBytesSync() => _delegate.readAsBytesSync();

  @override
  String readAsStringSync() => _delegate.readAsStringSync();

  @override
  fs.File renameSync(String newPath) =>
      _RecordingFile(_provider, _delegate.renameSync(newPath));

  @override
  fs.Resource resolveSymbolicLinksSync() =>
      _delegate.resolveSymbolicLinksSync();

  @override
  Uri toUri() => _delegate.toUri();

  @override
  fs.ResourceWatcher watch() => _delegate.watch();

  @override
  void writeAsBytesSync(List<int> bytes) => _delegate.writeAsBytesSync(bytes);

  @override
  void writeAsStringSync(String content) =>
      _delegate.writeAsStringSync(content);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('analyzer_summary_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('BoundedResourceProvider', () {
    test('stops upward folder walks at primaryRoot and blocks ancestor probes without statting disk', () {
      final anc1 = Directory(p.join(tempDir.path, 'anc1'))..createSync();
      final anc2 = Directory(p.join(anc1.path, 'anc2'))..createSync();
      final project = Directory(p.join(anc2.path, 'project'))..createSync();
      final srcDir = Directory(p.join(project.path, 'src', 'lib'))
        ..createSync(recursive: true);

      // Plant poison config/workspace files in ancestor directories.
      final poisonOptions = File(p.join(anc2.path, 'analysis_options.yaml'))
        ..writeAsStringSync('analyzer:\n  exclude:\n    - "**"\n');
      final poisonPubspec = File(p.join(anc1.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: poison_pkg\n');
      final poisonWorkspace = File(p.join(anc1.path, 'WORKSPACE'))
        ..writeAsStringSync('');
      final poisonBuildGn = File(p.join(anc2.path, 'BUILD.gn'))
        ..writeAsStringSync('');
      final poisonDartTool = Directory(p.join(anc2.path, '.dart_tool'))
        ..createSync();
      final poisonPkgConfig = File(
        p.join(poisonDartTool.path, 'package_config.json'),
      )..writeAsStringSync('{"configVersion": 2, "packages": []}');

      final projectOptions = File(p.join(project.path, 'analysis_options.yaml'))
        ..writeAsStringSync('linter:\n  rules: []\n');
      final srcFile = File(p.join(srcDir.path, 'a.dart'))
        ..writeAsStringSync('int x = 1;\n');

      final recorder = _RecordingResourceProvider(
        PhysicalResourceProvider.INSTANCE,
      );
      final bounded = BoundedResourceProvider(
        recorder,
        primaryRoot: project.path,
        boundaryRoots: {project.path},
        allowedFiles: {srcFile.path, projectOptions.path},
        blockAnalysisOptions: false,
      );

      // Walking upward from srcFile via `.parent` / `isRoot` must stop at `project`.
      final visitedFolders = <String>[];
      var current = bounded.getFile(srcFile.path).parent;
      while (true) {
        visitedFolders.add(p.normalize(p.absolute(current.path)));
        if (current.isRoot) break;
        current = current.parent;
      }
      expect(visitedFolders, [
        p.normalize(p.absolute(srcDir.path)),
        p.normalize(p.absolute(p.join(project.path, 'src'))),
        p.normalize(p.absolute(project.path)),
      ]);
      expect(
        visitedFolders,
        isNot(contains(p.normalize(p.absolute(anc2.path)))),
      );
      expect(
        visitedFolders,
        isNot(contains(p.normalize(p.absolute(anc1.path)))),
      );

      // Directly probing poison ancestor files returns false in memory and
      // never reaches the underlying recording provider.
      recorder.checkedPaths.clear();
      expect(bounded.getFile(poisonOptions.path).exists, isFalse);
      expect(bounded.getFile(poisonPubspec.path).exists, isFalse);
      expect(bounded.getFile(poisonWorkspace.path).exists, isFalse);
      expect(bounded.getFile(poisonBuildGn.path).exists, isFalse);
      expect(bounded.getFile(poisonPkgConfig.path).exists, isFalse);
      expect(bounded.getFolder(poisonDartTool.path).exists, isFalse);
      expect(
        recorder.checkedPaths,
        isEmpty,
        reason: 'blocked ancestor paths must not trigger physical stat calls',
      );

      // Staged project's own analysis_options.yaml is allowed in analyze mode.
      expect(bounded.getFile(projectOptions.path).exists, isTrue);

      // In summarize mode (`blockAnalysisOptions: true`), even an
      // analysis_options.yaml inside primaryRoot is blocked.
      final summarizeBounded = BoundedResourceProvider(
        recorder,
        primaryRoot: project.path,
        boundaryRoots: {project.path},
        allowedFiles: {srcFile.path},
        blockAnalysisOptions: true,
      );
      recorder.checkedPaths.clear();
      expect(summarizeBounded.getFile(projectOptions.path).exists, isFalse);
      expect(recorder.checkedPaths, isEmpty);
    });
  });

  group('SummaryByteCache', () {
    test('detects in-place .sum mutation with identical size and mtime when digest is absent', () {
      final sumFile = File(p.join(tempDir.path, 'dep.sum'));
      final fixedTime = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      sumFile.writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8]);
      sumFile.setLastModifiedSync(fixedTime);

      final cache = SummaryByteCache();
      final provider = SummaryCachingResourceProvider(
        PhysicalResourceProvider.INSTANCE,
        cache,
      );

      // Request 1 with no digest in WorkRequest.inputs.
      cache.beginRequest(const {});
      expect(provider.getFile(sumFile.path).readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);

      // Mutate `dep.sum` in-place to different bytes of the exact same length
      // and restore the exact same modification timestamp.
      sumFile.writeAsBytesSync([8, 7, 6, 5, 4, 3, 2, 1]);
      sumFile.setLastModifiedSync(fixedTime);
      expect(sumFile.statSync().size, 8);
      expect(sumFile.statSync().modified, fixedTime);

      // Request 2 with no digest in WorkRequest.inputs must NOT return stale bytes.
      cache.beginRequest(const {});
      expect(provider.getFile(sumFile.path).readAsBytesSync(), [
        8,
        7,
        6,
        5,
        4,
        3,
        2,
        1,
      ]);
    });
  });
}
