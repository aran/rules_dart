// The outlines of a target's VM kernel modules: what the modules and
// entrypoints that depend on them compile against, so that an edit inside a
// function body changes nothing they read and Bazel reuses their compiles.
//
// Usage: outline_tool [--load <dill>]... [--module <dill> --outline <dill>]...
//
// `--load` names the kernel the modules refer to (the platform, and the
// outlines of the dependencies they reach), which the writer needs to resolve
// their references. Each `--module` is stripped to its `--outline`, in order,
// so that a later one may refer to an earlier one.
//
// A module's outline is its kernel with function bodies and field initialisers
// removed. The input is `kernel_worker`'s full output, after the VM's modular
// transforms, because a dependent's own transforms read what those added. What
// a dependent's compile reads is kept:
//
// * mixins, `mixin class`es and every class of a pre-3.0 library, whole and
//   with their source positions: the VM copies a mixin's members, bodies and
//   positions included, into each class that applies it;
// * const constructors, const fields and procedures, and the final instance
//   fields of a class with a const constructor: constant evaluation runs them;
// * redirecting factories, parameter default values and annotations;
// * the members the FFI transform generates (named with a `#`) in `Struct`,
//   `Union` and `AbiSpecificInteger` subclasses: dependents' FFI transforms
//   look them up.
//
// The VM's call-site metadata, which describes calls inside bodies, is
// dropped. Anything else is a construct this tool does not know, and it fails rather
// than guess what a dependent might need.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/binary/tag.dart';
import 'package:kernel/kernel.dart';

const _flag = '--@rules_dart//dart:outline_kernel=false';

void main(List<String> argv) {
  // A `@paramsfile`, one argument per line, stands for its lines: a package
  // with many dependencies names more files than a Windows command line holds.
  final args = [
    for (final arg in argv)
      if (arg.startsWith('@'))
        ...const LineSplitter().convert(
          File(arg.substring(1)).readAsStringSync(),
        )
      else
        arg,
  ];
  final load = <String>[], modules = <String>[], outlines = <String>[];
  if (args.length.isOdd) _usage();
  for (var i = 0; i < args.length; i += 2) {
    (switch (args[i]) {
      '--load' => load,
      '--module' => modules,
      '--outline' => outlines,
      _ => _usage(),
    }).add(args[i + 1]);
  }
  if (modules.length != outlines.length) _usage();

  final component = Component();
  var reading = '';
  try {
    for (final dill in load) {
      reading = dill;
      BinaryBuilder(File(dill).readAsBytesSync()).readComponent(component);
    }
    for (var i = 0; i < modules.length; i++) {
      reading = modules[i];
      File(outlines[i]).writeAsBytesSync(
        outline(component, File(modules[i]).readAsBytesSync()),
      );
    }
    return;
  } on Unrecognised catch (e) {
    stderr.writeln('$reading $e, which the outline stripper does not know.');
  } on InvalidKernelVersionError catch (e) {
    stderr.writeln(
      '$reading is kernel format ${e.version}; this outline stripper reads '
      'only format ${Tag.BinaryFormatVersion}, that of the Dart SDK whose '
      'pkg/kernel it is built on. A kernel SDK\'s outline tool must be built '
      'from the same SDK as its compiler.',
    );
  }
  stderr.writeln(
    'Build with $_flag to compile dependents against full kernels instead.',
  );
  exitCode = 1;
}

Never _usage() {
  stderr.writeln(
    'usage: outline_tool [--load <dill>]... '
    '[--module <dill> --outline <dill>]...\n'
    '       outline_tool @paramsfile   (one argument per line)',
  );
  exit(2);
}

class Unrecognised implements Exception {
  Unrecognised(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The outline of one module's kernel file, read into [component], which
/// holds what it refers to.
Uint8List outline(Component component, Uint8List bytes) {
  _checkMetadata(bytes);
  final before = component.libraries.length;
  BinaryBuilder(bytes).readComponent(component);
  final own = component.libraries.sublist(before);
  final whole = <Class>{};
  for (final library in own) {
    final legacy = library.languageVersion.major < 3;
    library.procedures.forEach(_procedure);
    for (final field in library.fields) {
      _field(field, keepInitializer: false);
    }
    for (final c in library.classes) {
      if (legacy || c.isMixinDeclaration || c.isMixinClass) {
        whole.add(c);
      } else {
        _class(c);
      }
    }
    library.problemsAsJson = null;
  }
  // The module's own source table (reading it into [component] merged it with
  // the others), with line tables only for the files whose positions
  // dependents copy: a dependent's compile copies the entries it refers to.
  final files = {for (final c in whole) c.fileUri};
  final written = Component(
    nameRoot: component.root,
    uriToSource: {
      for (final MapEntry(key: uri, value: source)
          in loadComponentSourceFromBytes(bytes).uriToSource.entries)
        uri: files.contains(uri)
            ? source
            : Source(const [], Uint8List(0), source.importUri, source.fileUri),
    },
  )..libraries.addAll(own);
  final sink = _BytesSink();
  _OutlinePrinter(sink, whole).writeComponentFile(written);
  return sink.builder.takeBytes();
}

void _class(Class c) {
  final ffi = _ffiKind(c);
  final constClass = c.constructors.any((k) => k.isConst);
  bool generated(Member m) => ffi == _Ffi.compound && m.name.text.contains('#');
  for (final p in c.procedures) {
    if (!generated(p)) _procedure(p);
  }
  for (final f in c.fields) {
    _field(f, keepInitializer: constClass && f.isFinal && !f.isStatic);
  }
  for (final k in c.constructors) {
    if (k.isConst || generated(k)) continue;
    k.initializers.clear();
    k.function.body = null;
  }
}

void _procedure(Procedure p) {
  final bodyless = switch (p.stubKind) {
    ProcedureStubKind.Regular ||
    ProcedureStubKind.ConcreteForwardingStub ||
    ProcedureStubKind.NoSuchMethodForwarder ||
    ProcedureStubKind.ConcreteMixinStub => false,
    ProcedureStubKind.AbstractForwardingStub ||
    ProcedureStubKind.MemberSignature ||
    ProcedureStubKind.AbstractMixinStub ||
    ProcedureStubKind.RepresentationField => true,
  };
  if (bodyless) {
    if (p.function.body != null) {
      throw Unrecognised('has a ${p.stubKind.name} with a body, ${_name(p)}');
    }
    return;
  }
  if (p.isConst || p.isRedirectingFactory) return;
  p.function.body = null;
}

void _field(Field f, {required bool keepInitializer}) {
  if (f.isConst || keepInitializer) return;
  f.initializer = null;
}

enum _Ffi { none, compound }

/// What kind of `dart:ffi` class [c] extends directly, if any. Subclasses of
/// FFI types extend them directly: their subclasses are `final` or `sealed`.
_Ffi _ffiKind(Class c) {
  final name = c.supertype?.className.canonicalName;
  if (name?.parent?.name != 'dart:ffi') return _Ffi.none;
  return switch (name!.name) {
    'Struct' || 'Union' || 'AbiSpecificInteger' => _Ffi.compound,
    'Opaque' => _Ffi.none,
    final other => throw Unrecognised(
      'has ${_name(c)}, a subclass of dart:ffi $other',
    ),
  };
}

String _name(NamedNode n) => n.reference.canonicalName?.toString() ?? '$n';

/// Metadata (backend data keyed by node) that the outline drops: the VM's
/// modular transforms annotate call sites in bodies with it, for the VM
/// itself, and the front end reads none of it from a dependency.
const _droppedMetadata = {'vm.call-site-attributes.metadata'};

/// Fails on metadata other than [_droppedMetadata], which reading would
/// silently drop too: a module that has some is not one this tool knows.
void _checkMetadata(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int u32(int at) => data.getUint32(at);
  final end = bytes.length;
  if (end < 8 || u32(end - 4) != end) {
    throw Unrecognised('is not a single kernel component');
  }
  // The component index ends: ..., string table offset, start of index,
  // main method, library offsets (count + 1), library count, file size.
  final libraryCount = u32(end - 8);
  final stringTable = u32(end - 8 - 4 * (libraryCount + 1) - 12);
  final mappings = u32(stringTable - 4);
  if (mappings == 0) return;
  // Each mapping, read backwards: its tag, its pairs, and their count.
  final tags = <String>[];
  var mappingEnd = stringTable - 4;
  for (var i = 0; i < mappings; i++) {
    final pairs = u32(mappingEnd - 4);
    final start = mappingEnd - 4 - 8 * pairs;
    tags.add(_string(bytes, stringTable, u32(start - 4)));
    mappingEnd = start - 4;
  }
  final unknown = tags.where((t) => !_droppedMetadata.contains(t));
  if (unknown.isNotEmpty)
    throw Unrecognised('has metadata ${unknown.join(', ')}');
}

/// String [index] of the string table at [offset]: the end offsets of the
/// strings, then their UTF-8 bytes.
String _string(Uint8List bytes, int offset, int index) {
  var at = offset;
  int uint() {
    final b = bytes[at];
    if (b & 0x80 == 0) return bytes[at++];
    if (b & 0x40 == 0) {
      final v = (b & 0x3f) << 8 | bytes[at + 1];
      at += 2;
      return v;
    }
    final v =
        (b & 0x3f) << 24 |
        bytes[at + 1] << 16 |
        bytes[at + 2] << 8 |
        bytes[at + 3];
    at += 4;
    return v;
  }

  final count = uint();
  final ends = [for (var i = 0; i < count; i++) uint()];
  final start = index == 0 ? 0 : ends[index - 1];
  return String.fromCharCodes(bytes, at + start, at + ends[index]);
}

class _BytesSink implements Sink<List<int>> {
  final builder = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => builder.add(data);
  @override
  void close() {}
}

/// Writes source positions only inside [whole], the classes dependents copy:
/// elsewhere a moved line would change the outline, and nothing reads them.
class _OutlinePrinter extends BinaryPrinter {
  _OutlinePrinter(super.sink, this.whole) : super(includeSourceBytes: false);

  final Set<Class> whole;
  bool _inWhole = false;

  @override
  void writeClassNode(Class node) {
    final outer = _inWhole;
    _inWhole = whole.contains(node);
    super.writeClassNode(node);
    _inWhole = outer;
  }

  @override
  void writeOffset(int offset) =>
      super.writeOffset(_inWhole ? offset : TreeNode.noOffset);
}
