// Strips a compiled Dart Kernel (`.dill`) component to a deterministic outline
// component in-memory for modular `--input-summary` compilation.
//
// Outline soundness: any class that can be used as a mixin keeps its member
// bodies and field initializers in the outline, because the VM mixin
// transformation clones them into downstream mixin applications. That covers
// `mixin` declarations, `mixin class` declarations, and every `class` in a
// library whose language version is below 3.0.
//
// Format guard: reads the 32-bit kernel format version from the header and
// accepts only [supportedKernelFormatVersions] (format version 138, used by
// Dart 3.13.x). On any other version, logs a diagnostic to `stderr` and falls
// back to returning the unstripped input `.dill` bytes unchanged, never
// emitting a malformed `.dill`.

import 'dart:io' show stderr;
import 'dart:typed_data';

/// The Dart Kernel binary format versions (`Tag.BinaryFormatVersion`) that
/// [stripDillToOutline] and `stripSourceCodeFromDill` were written and tested
/// for (format version 138, Dart SDK 3.13.x).
///
/// On any other format version, both strippers write a diagnostic to `stderr`
/// and fall back to returning the unstripped input `.dill` bytes unchanged.
const Set<int> supportedKernelFormatVersions = {Tag.BinaryFormatVersion};

class Tag {
  static const int ComponentFile = 0x90ABCDEF;
  static const int BinaryFormatVersion = 138;

  static const int Nothing = 0;
  static const int Something = 1;

  static const int Class = 2;
  static const int Extension = 115;
  static const int ExtensionTypeDeclaration = 85;

  static const int FunctionNode = 3;

  // Members
  static const int Field = 4;
  static const int Constructor = 5;
  static const int Procedure = 6;

  // Initializers
  static const int InvalidInitializer = 7;
  static const int FieldInitializer = 8;
  static const int SuperInitializer = 9;
  static const int RedirectingInitializer = 10;
  static const int LocalInitializer = 11;
  static const int AssertInitializer = 12;

  // Expressions
  static const int CheckLibraryIsLoaded = 13;
  static const int LoadLibrary = 14;
  static const int EqualsNull = 15;
  static const int EqualsCall = 16;
  static const int StaticTearOff = 17;
  static const int ConstStaticInvocation = 18;
  static const int InvalidExpression = 19;
  static const int VariableGet = 20;
  static const int VariableSet = 21;
  static const int AbstractSuperPropertyGet = 22;
  static const int AbstractSuperPropertySet = 23;
  static const int SuperPropertyGet = 24;
  static const int SuperPropertySet = 25;
  static const int StaticGet = 26;
  static const int StaticSet = 27;
  static const int AbstractSuperMethodInvocation = 28;
  static const int SuperMethodInvocation = 29;
  static const int StaticInvocation = 30;
  static const int ConstructorInvocation = 31;
  static const int ConstConstructorInvocation = 32;
  static const int Not = 33;
  static const int LogicalExpression = 34;
  static const int ConditionalExpression = 35;
  static const int StringConcatenation = 36;
  static const int IsExpression = 37;
  static const int AsExpression = 38;
  static const int StringLiteral = 39;
  static const int DoubleLiteral = 40;
  static const int TrueLiteral = 41;
  static const int FalseLiteral = 42;
  static const int NullLiteral = 43;
  static const int SymbolLiteral = 44;
  static const int TypeLiteral = 45;
  static const int ThisExpression = 46;
  static const int Rethrow = 47;
  static const int Throw = 48;
  static const int ListLiteral = 49;
  static const int MapLiteral = 50;
  static const int AwaitExpression = 51;
  static const int FunctionExpression = 52;
  static const int Let = 53;
  static const int Instantiation = 54;
  static const int PositiveIntLiteral = 55;
  static const int NegativeIntLiteral = 56;
  static const int BigIntLiteral = 57;
  static const int ConstListLiteral = 58;
  static const int ConstMapLiteral = 59;
  static const int ConstructorTearOff = 60;
  static const int BlockExpression = 82;
  static const int TypedefTearOff = 83;
  static const int RedirectingFactoryTearOff = 84;

  static const int RecordIndexGet = 101;
  static const int RecordNameGet = 102;
  static const int RecordLiteral = 104;
  static const int ConstRecordLiteral = 105;
  static const int ConstantExpression = 106;
  static const int FileUriConstantExpression = 108;
  static const int SetLiteral = 109;
  static const int ConstSetLiteral = 110;
  static const int ListConcatenation = 111;
  static const int SetConcatenation = 112;
  static const int MapConcatenation = 113;
  static const int InstanceCreation = 114;
  static const int FileUriExpression = 116;

  static const int NullCheck = 117;
  static const int InstanceGet = 118;
  static const int InstanceSet = 119;
  static const int InstanceInvocation = 120;
  static const int InstanceGetterInvocation = 89;
  static const int InstanceTearOff = 121;
  static const int DynamicGet = 122;
  static const int DynamicSet = 123;
  static const int DynamicInvocation = 124;
  static const int FunctionInvocation = 125;
  static const int FunctionTearOff = 126;
  static const int LocalFunctionInvocation = 127;
  static const int RedirectingFactoryInvocation = 153;

  // Statements
  static const int ExpressionStatement = 61;
  static const int Block = 62;
  static const int EmptyStatement = 63;
  static const int AssertStatement = 64;
  static const int LabeledStatement = 65;
  static const int BreakStatement = 66;
  static const int WhileStatement = 67;
  static const int DoStatement = 68;
  static const int ForStatement = 69;
  static const int ForInStatement = 70;
  static const int SwitchStatement = 71;
  static const int ContinueSwitchStatement = 72;
  static const int IfStatement = 73;
  static const int ReturnStatement = 74;
  static const int TryCatch = 75;
  static const int TryFinally = 76;
  static const int YieldStatement = 77;
  static const int VariableStatement = 78;
  static const int FunctionDeclaration = 79;
  static const int AsyncForInStatement = 80;
  static const int AssertBlock = 81;

  // Types
  static const int TypedefType = 87;
  static const int InvalidType = 90;
  static const int DynamicType = 91;
  static const int VoidType = 92;
  static const int InterfaceType = 93;
  static const int FunctionType = 94;
  static const int TypeParameterType = 95;
  static const int SimpleInterfaceType = 96;
  static const int SimpleFunctionType = 97;
  static const int NeverType = 98;
  static const int IntersectionType = 99;
  static const int RecordType = 100;
  static const int ExtensionType = 103;
  static const int FutureOrType = 107;
  static const int NullType = 152;

  // Patterns
  static const int AndPattern = 128;
  static const int AssignedVariablePattern = 129;
  static const int CastPattern = 130;
  static const int ConstantPattern = 131;
  static const int InvalidPattern = 132;
  static const int ListPattern = 133;
  static const int MapPattern = 134;
  static const int NamedPattern = 135;
  static const int NullAssertPattern = 136;
  static const int NullCheckPattern = 137;
  static const int ObjectPattern = 138;
  static const int OrPattern = 139;
  static const int RecordPattern = 140;
  static const int RelationalPattern = 141;
  static const int RestPattern = 142;
  static const int VariablePattern = 143;
  static const int WildcardPattern = 144;
  static const int MapPatternEntry = 145;
  static const int MapPatternRestEntry = 146;
  static const int PatternSwitchStatement = 147;
  static const int SwitchExpression = 148;
  static const int IfCaseStatement = 149;
  static const int PatternAssignment = 150;
  static const int PatternVariableDeclaration = 151;

  static const int VariableDeclaration = 154;

  static const int SpecializedTagHighBits = 0xE0;
  static const int SpecializedTagMask = 0xF8;
  static const int SpecializedPayloadMask = 0x7;

  static const int SpecializedVariableGet = 224;
  static const int SpecializedVariableSet = 232;
  static const int SpecializedIntLiteral = 240;
}

class ConstantTag {
  static const int NullConstant = 0;
  static const int BoolConstant = 1;
  static const int IntConstant = 2;
  static const int DoubleConstant = 3;
  static const int StringConstant = 4;
  static const int SymbolConstant = 5;
  static const int MapConstant = 6;
  static const int ListConstant = 7;
  static const int SetConstant = 13;
  static const int InstanceConstant = 8;
  static const int InstantiationConstant = 9;
  static const int StaticTearOffConstant = 10;
  static const int TypeLiteralConstant = 11;
  static const int UnevaluatedConstant = 12;
  static const int TypedefTearOffConstant = 14;
  static const int ConstructorTearOffConstant = 15;
  static const int RedirectingFactoryTearOffConstant = 16;
  static const int RecordConstant = 17;
}

int _readUint32Be(Uint8List bytes, int offset) {
  return ((bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3]) >>>
      0;
}

/// Strips a compiled Dart Kernel (`.dill`) component to a deterministic
/// outline component in-memory for modular `--input-summary` compilation.
///
/// Reads the 32-bit kernel format version at byte offset 4 of each
/// component's header and accepts only [supportedKernelFormatVersions]
/// (version 138, Dart 3.13.x). On any other format version (or an invalid
/// header), writes a diagnostic to [errSink] (defaulting to [stderr]) and
/// falls back to returning [bytes] unstripped, never emitting a malformed
/// `.dill`.
Uint8List stripDillToOutline(Uint8List bytes, {StringSink? errSink}) {
  final sink = errSink ?? stderr;
  if (bytes.length < 18) {
    sink.writeln(
      'dill_outline: input too short for kernel header (${bytes.length} bytes); '
      'falling back to unstripped dill.',
    );
    return bytes;
  }
  final magic = _readUint32Be(bytes, 0);
  if (magic != Tag.ComponentFile) {
    sink.writeln(
      'dill_outline: invalid kernel magic 0x${magic.toRadixString(16)} '
      '(expected 0x${Tag.ComponentFile.toRadixString(16)}); '
      'falling back to unstripped dill.',
    );
    return bytes;
  }
  final formatVersion = _readUint32Be(bytes, 4);
  if (!supportedKernelFormatVersions.contains(formatVersion)) {
    sink.writeln(
      'dill_outline: unsupported kernel format version $formatVersion '
      '(supported: ${supportedKernelFormatVersions.join(', ')}); '
      'falling back to unstripped dill.',
    );
    return bytes;
  }
  final len = bytes.length;
  final lastCompSize = _readUint32Be(bytes, len - 4);
  if (lastCompSize == len) {
    return _DillOutlineStripper(bytes).strip();
  }
  final slices = <Uint8List>[];
  int end = len;
  while (end > 0) {
    if (end < 18) {
      sink.writeln(
        'dill_outline: invalid sub-component end offset $end; '
        'falling back to unstripped dill.',
      );
      return bytes;
    }
    final compSize = _readUint32Be(bytes, end - 4);
    if (compSize < 18 || compSize > end) {
      sink.writeln(
        'dill_outline: invalid sub-component size $compSize at end=$end; '
        'falling back to unstripped dill.',
      );
      return bytes;
    }
    final slice = Uint8List.sublistView(bytes, end - compSize, end);
    final sliceMagic = _readUint32Be(slice, 0);
    if (sliceMagic != Tag.ComponentFile) {
      sink.writeln(
        'dill_outline: invalid sub-component kernel magic 0x${sliceMagic.toRadixString(16)}; '
        'falling back to unstripped dill.',
      );
      return bytes;
    }
    final sliceVersion = _readUint32Be(slice, 4);
    if (!supportedKernelFormatVersions.contains(sliceVersion)) {
      sink.writeln(
        'dill_outline: unsupported kernel format version $sliceVersion '
        '(supported: ${supportedKernelFormatVersions.join(', ')}); '
        'falling back to unstripped dill.',
      );
      return bytes;
    }
    slices.add(slice);
    end -= compSize;
  }
  final out = BytesBuilder(copy: false);
  for (int i = slices.length - 1; i >= 0; i--) {
    out.add(_DillOutlineStripper(slices[i]).strip());
  }
  return out.takeBytes();
}

class _ByteWriter {
  Uint8List _buf = Uint8List(65536);
  int _len = 0;
  bool enabled = true;

  int get length => _len;

  void _grow(int minAdd) {
    int newCap = _buf.length * 2;
    while (newCap < _len + minAdd) {
      newCap *= 2;
    }
    final next = Uint8List(newCap);
    next.setRange(0, _len, _buf);
    _buf = next;
  }

  void writeByte(int b) {
    if (!enabled) return;
    if (_len >= _buf.length) _grow(1);
    _buf[_len++] = b;
  }

  void writeBytes(Uint8List data, [int start = 0, int? end]) {
    if (!enabled) return;
    final actualEnd = end ?? data.length;
    final count = actualEnd - start;
    if (count <= 0) return;
    if (_len + count > _buf.length) _grow(count);
    _buf.setRange(_len, _len + count, data, start);
    _len += count;
  }

  void writeUInt30(int value) {
    if (!enabled) return;
    assert(value >= 0 && value < (1 << 30));
    if (value < 0x80) {
      writeByte(value);
    } else if (value < 0x4000) {
      writeByte((value >> 8) | 0x80);
      writeByte(value & 0xFF);
    } else {
      writeByte((value >> 24) | 0xC0);
      writeByte((value >> 16) & 0xFF);
      writeByte((value >> 8) & 0xFF);
      writeByte(value & 0xFF);
    }
  }

  void writeUInt32(int value) {
    if (!enabled) return;
    if (_len + 4 > _buf.length) _grow(4);
    _buf[_len++] = (value >> 24) & 0xFF;
    _buf[_len++] = (value >> 16) & 0xFF;
    _buf[_len++] = (value >> 8) & 0xFF;
    _buf[_len++] = value & 0xFF;
  }

  Uint8List toBytes() => Uint8List.sublistView(_buf, 0, _len);
}

class _DillOutlineStripper {
  final Uint8List _in;
  int _pos = 0;
  final _ByteWriter _out = _ByteWriter();

  late final int _inSourceTableOffset;
  late final int _inConstantTableOffset;
  late final int _inConstantTableIndexOffset;
  late final int _inLinkTableOffset;
  late final int _inStringTableOffset;
  late final List<int> _inLibraryOffsets;
  late final int _inLibraryCount;

  late final Int32List _inStrStart;
  late final Int32List _inStrEnd;
  late final Int32List _inCanonParent;
  late final Int32List _inCanonString;
  late final List<Uint8List> _inUriStrings;
  late final List<Uint8List> _inImportUriStrings;
  late final Int32List _inConstOffsets;

  late final Int32List _strRemap;
  final List<int> _outStrings = <int>[];

  late final Int32List _canonRemap;
  final List<int> _outCanonParent = <int>[];
  final List<int> _outCanonOldString = <int>[];

  late final Int32List _uriRemap;
  final List<int> _outUris = <int>[];
  final List<bool> _sourcesUsedInLibrary = <bool>[false];

  late final Int32List _constRemap;
  final List<int> _outConsts = <int>[];

  final Map<int, int> _varOffsetMap = <int, int>{};

  _DillOutlineStripper(this._in);

  bool get _emitting => _out.enabled;
  set _emitting(bool v) => _out.enabled = v;

  int _readByte() => _in[_pos++];

  int _readUInt30() {
    final byte = _in[_pos++];
    if ((byte & 0x80) == 0) {
      return byte;
    } else if ((byte & 0x40) == 0) {
      return ((byte & 0x3F) << 8) | _in[_pos++];
    } else {
      final b1 = _in[_pos++];
      final b2 = _in[_pos++];
      final b3 = _in[_pos++];
      return ((byte & 0x3F) << 24) | (b1 << 16) | (b2 << 8) | b3;
    }
  }

  int _readUInt32() {
    final b0 = _in[_pos++];
    final b1 = _in[_pos++];
    final b2 = _in[_pos++];
    final b3 = _in[_pos++];
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
  }

  int _readUInt32At(int offset) {
    return (_in[offset] << 24) |
        (_in[offset + 1] << 16) |
        (_in[offset + 2] << 8) |
        _in[offset + 3];
  }

  Uint8List strip() {
    _parseIndexAndInputTables();

    _out.writeBytes(_in, 0, 18);
    _out.writeUInt30(0); // problemsAsJson

    final outLibraryOffsets = <int>[];
    for (int i = 0; i < _inLibraryCount; i++) {
      _pos = _inLibraryOffsets[i];
      final endOffset = _inLibraryOffsets[i + 1];
      outLibraryOffsets.add(_out.length);
      _procLibrary(endOffset);
    }

    final outSourceTableOffset = _out.length;
    final uriCount = _outUris.length;
    _out.writeUInt32(uriCount);
    final uriEntryOffsets = Int32List(uriCount);
    for (int i = 0; i < uriCount; i++) {
      uriEntryOffsets[i] = _out.length;
      final oldUriIdx = _outUris[i];
      final uriBytes = _inUriStrings[oldUriIdx];
      _out.writeUInt30(uriBytes.length);
      _out.writeBytes(uriBytes);
      _out.writeUInt30(0); // empty source bytes
      _out.writeUInt30(0); // 0 lineStarts
      final importUriBytes = _inImportUriStrings[oldUriIdx];
      _out.writeUInt30(importUriBytes.length);
      _out.writeBytes(importUriBytes);
      _out.writeUInt30(0); // 0 constantCoverageConstructors
    }
    for (int i = 0; i < uriCount; i++) {
      _out.writeUInt32(uriEntryOffsets[i]);
    }

    final outConstantTableOffset = _out.length;
    final constCount = _outConsts.length;
    _out.writeUInt30(constCount);
    final constRelativeOffsets = Int32List(constCount);
    for (int i = 0; i < constCount; i++) {
      constRelativeOffsets[i] = _out.length - outConstantTableOffset;
      final oldConstIdx = _outConsts[i];
      _pos = _inConstantTableOffset + _inConstOffsets[oldConstIdx];
      _procConstantTableEntry();
    }
    final outConstantTableIndexOffset = _out.length;
    for (int i = 0; i < constCount; i++) {
      _out.writeUInt32(constRelativeOffsets[i]);
    }
    _out.writeUInt32(constCount);

    final outLinkTableOffset = _out.length;
    final canonCount = _outCanonParent.length;
    _out.writeUInt30(canonCount);
    for (int i = 0; i < canonCount; i++) {
      _out.writeUInt30(_outCanonParent[i]);
      final strIdx = _remapString(_outCanonOldString[i]);
      _out.writeUInt30(strIdx);
    }

    final metaPadding = ((_out.length + 7) & -8) - _out.length;
    for (int i = 0; i < metaPadding; i++) {
      _out.writeByte(0);
    }
    final outMetadataPayloadsOffset = _out.length;
    final outMetadataMappingsOffset = _out.length;
    _out.writeUInt32(0);

    final outStringTableOffset = _out.length;
    final strCount = _outStrings.length;
    _out.writeUInt30(strCount);
    int cumulativeBytes = 0;
    for (int i = 0; i < strCount; i++) {
      final oldStrIdx = _outStrings[i];
      if (oldStrIdx >= 0) {
        cumulativeBytes += _inStrEnd[oldStrIdx] - _inStrStart[oldStrIdx];
      }
      _out.writeUInt30(cumulativeBytes);
    }
    for (int i = 0; i < strCount; i++) {
      final oldStrIdx = _outStrings[i];
      if (oldStrIdx >= 0) {
        final s = _inStrStart[oldStrIdx];
        final e = _inStrEnd[oldStrIdx];
        _out.writeBytes(_in, s, e);
      }
    }

    final componentIndexOffset = _out.length;
    final numFixedFields = 9 + (_inLibraryCount + 1) + 2;
    final unalignedSize = componentIndexOffset + numFixedFields * 4;
    final indexPadding = ((unalignedSize + 7) & -8) - unalignedSize;
    for (int i = 0; i < indexPadding; i++) {
      _out.writeByte(0);
    }
    _out.writeUInt32(outSourceTableOffset);
    _out.writeUInt32(outConstantTableOffset);
    _out.writeUInt32(outConstantTableIndexOffset);
    _out.writeUInt32(outLinkTableOffset);
    _out.writeUInt32(outMetadataPayloadsOffset);
    _out.writeUInt32(outMetadataMappingsOffset);
    _out.writeUInt32(outStringTableOffset);
    _out.writeUInt32(componentIndexOffset);
    _out.writeUInt32(0); // mainMethodReference = 0
    for (int i = 0; i < _inLibraryCount; i++) {
      _out.writeUInt32(outLibraryOffsets[i]);
    }
    _out.writeUInt32(outSourceTableOffset);
    _out.writeUInt32(_inLibraryCount);
    _out.writeUInt32(_out.length + 4);

    return _out.toBytes();
  }

  void _parseIndexAndInputTables() {
    final fileSize = _in.length;
    _inLibraryCount = _readUInt32At(fileSize - 8);
    final numFixedFields = 9 + (_inLibraryCount + 1) + 2;
    int idxPos = fileSize - numFixedFields * 4;
    _inSourceTableOffset = _readUInt32At(idxPos);
    idxPos += 4;
    _inConstantTableOffset = _readUInt32At(idxPos);
    idxPos += 4;
    _inConstantTableIndexOffset = _readUInt32At(idxPos);
    idxPos += 4;
    _inLinkTableOffset = _readUInt32At(idxPos);
    idxPos += 4;
    idxPos += 8;
    _inStringTableOffset = _readUInt32At(idxPos);
    idxPos += 4;
    idxPos += 8;
    _inLibraryOffsets = List<int>.generate(
      _inLibraryCount + 1,
      (i) => _readUInt32At(idxPos + i * 4),
      growable: false,
    );

    _pos = _inStringTableOffset;
    final strCount = _readUInt30();
    final endOffsets = Int32List(strCount);
    for (int i = 0; i < strCount; i++) {
      endOffsets[i] = _readUInt30();
    }
    final strDataBase = _pos;
    _inStrStart = Int32List(strCount);
    _inStrEnd = Int32List(strCount);
    int prevEnd = 0;
    int emptyStrOldIdx = -1;
    for (int i = 0; i < strCount; i++) {
      final end = endOffsets[i];
      _inStrStart[i] = strDataBase + prevEnd;
      _inStrEnd[i] = strDataBase + end;
      if (end == prevEnd && emptyStrOldIdx == -1) {
        emptyStrOldIdx = i;
      }
      prevEnd = end;
    }
    _strRemap = Int32List(strCount)..fillRange(0, strCount, -1);
    if (emptyStrOldIdx != -1) {
      _strRemap[emptyStrOldIdx] = 0;
      _outStrings.add(emptyStrOldIdx);
    } else {
      _outStrings.add(-1);
    }

    _pos = _inLinkTableOffset;
    final canonCount = _readUInt30();
    _inCanonParent = Int32List(canonCount);
    _inCanonString = Int32List(canonCount);
    for (int i = 0; i < canonCount; i++) {
      _inCanonParent[i] = _readUInt30();
      _inCanonString[i] = _readUInt30();
    }
    _canonRemap = Int32List(canonCount)..fillRange(0, canonCount, -1);

    _pos = _inSourceTableOffset;
    final uriCount = _readUInt32();
    _inUriStrings = List<Uint8List>.filled(uriCount, Uint8List(0));
    _inImportUriStrings = List<Uint8List>.filled(uriCount, Uint8List(0));
    for (int i = 0; i < uriCount; i++) {
      final uriLen = _readUInt30();
      _inUriStrings[i] = Uint8List.sublistView(_in, _pos, _pos + uriLen);
      _pos += uriLen;
      final srcLen = _readUInt30();
      _pos += srcLen;
      final lineCount = _readUInt30();
      for (int j = 0; j < lineCount; j++) {
        _readUInt30();
      }
      final impLen = _readUInt30();
      _inImportUriStrings[i] = Uint8List.sublistView(_in, _pos, _pos + impLen);
      _pos += impLen;
      final covCount = _readUInt30();
      for (int j = 0; j < covCount; j++) {
        _readUInt30();
      }
    }
    _uriRemap = Int32List(uriCount)..fillRange(0, uriCount, -1);

    final constCount = _readUInt32At(_inLinkTableOffset - 4);
    _inConstOffsets = Int32List(constCount);
    for (int i = 0; i < constCount; i++) {
      _inConstOffsets[i] = _readUInt32At(_inConstantTableIndexOffset + i * 4);
    }
    _constRemap = Int32List(constCount)..fillRange(0, constCount, -1);
  }

  int _remapString(int oldStrIdx) {
    if (!_emitting) return 0;
    final existing = _strRemap[oldStrIdx];
    if (existing != -1) return existing;
    if (_inStrEnd[oldStrIdx] == _inStrStart[oldStrIdx]) {
      _strRemap[oldStrIdx] = 0;
      return 0;
    }
    final next = _outStrings.length;
    _strRemap[oldStrIdx] = next;
    _outStrings.add(oldStrIdx);
    return next;
  }

  int _remapCanon(int oldBiased) {
    if (!_emitting || oldBiased == 0) return 0;
    final oldIdx = oldBiased - 1;
    final existing = _canonRemap[oldIdx];
    if (existing != -1) return existing + 1;
    final parentBiased = _inCanonParent[oldIdx];
    final newParentBiased = parentBiased == 0 ? 0 : _remapCanon(parentBiased);
    final newIdx = _outCanonParent.length;
    _outCanonParent.add(newParentBiased);
    _outCanonOldString.add(_inCanonString[oldIdx]);
    _canonRemap[oldIdx] = newIdx;
    return newIdx + 1;
  }

  int _remapUri(int oldUriIdx) {
    if (!_emitting) return 0;
    int newIdx = _uriRemap[oldUriIdx];
    if (newIdx == -1) {
      newIdx = _outUris.length;
      _uriRemap[oldUriIdx] = newIdx;
      _outUris.add(oldUriIdx);
    }
    while (_sourcesUsedInLibrary.length <= newIdx) {
      _sourcesUsedInLibrary.add(false);
    }
    _sourcesUsedInLibrary[newIdx] = true;
    return newIdx;
  }

  int _remapConst(int oldConstIdx) {
    if (!_emitting) return 0;
    final existing = _constRemap[oldConstIdx];
    if (existing != -1) return existing;
    final savedPos = _pos;
    _pos = _inConstantTableOffset + _inConstOffsets[oldConstIdx];
    _visitConstantChildrenForIndexing();
    _pos = savedPos;
    final newIdx = _outConsts.length;
    _constRemap[oldConstIdx] = newIdx;
    _outConsts.add(oldConstIdx);
    return newIdx;
  }

  void _procStringRef() {
    _out.writeUInt30(_remapString(_readUInt30()));
  }

  void _procCanonRef() {
    _out.writeUInt30(_remapCanon(_readUInt30()));
  }

  void _procUriRef() {
    _out.writeUInt30(_remapUri(_readUInt30()));
  }

  void _procOffset() {
    _readUInt30();
    _out.writeUInt30(0);
  }

  void _procName() {
    final oldStrIdx = _readUInt30();
    _out.writeUInt30(_remapString(oldStrIdx));
    final s = _inStrStart[oldStrIdx];
    final e = _inStrEnd[oldStrIdx];
    if (e > s && _in[s] == 95 /* '_' */ ) {
      _procCanonRef();
    }
  }

  void _procListOfStringsAsEmpty() {
    final len = _readUInt30();
    for (int i = 0; i < len; i++) {
      final byteLen = _readUInt30();
      _pos += byteLen;
    }
    _out.writeUInt30(0);
  }

  void _procLibrary(int endOffset) {
    final savedPos = _pos;
    _pos = endOffset - 4;
    final procCount = _readUInt32();
    _pos = endOffset - (procCount + 3) * 4;
    final classCount = _readUInt32();
    final inProcOffsets = Int32List(procCount + 1);
    for (int i = 0; i <= procCount; i++) {
      inProcOffsets[i] = _readUInt32();
    }
    _pos = endOffset - (procCount + classCount + 4) * 4;
    final inClassOffsets = Int32List(classCount + 1);
    for (int i = 0; i <= classCount; i++) {
      inClassOffsets[i] = _readUInt32();
    }
    _pos = savedPos;

    for (int i = 0; i < _sourcesUsedInLibrary.length; i++) {
      _sourcesUsedInLibrary[i] = false;
    }

    _out.writeByte(_readByte()); // flags
    final major = _readUInt30();
    _out.writeUInt30(major); // major
    _out.writeUInt30(_readUInt30()); // minor
    final isLegacyLibrary = major < 3;
    _procCanonRef(); // canonicalName
    _procStringRef(); // name
    _procUriRef(); // fileUri
    _procListOfStringsAsEmpty(); // problemsAsJson
    _procExpressionList(); // annotations

    final depCount = _readUInt30();
    _out.writeUInt30(depCount);
    for (int i = 0; i < depCount; i++) {
      _procOffset();
      _out.writeByte(_readByte());
      _procExpressionList();
      _procCanonRef();
      _procStringRef();
      final combCount = _readUInt30();
      _out.writeUInt30(combCount);
      for (int j = 0; j < combCount; j++) {
        _out.writeByte(_readByte());
        final nameCount = _readUInt30();
        _out.writeUInt30(nameCount);
        for (int k = 0; k < nameCount; k++) {
          _procStringRef();
        }
      }
    }

    final expCount = _readUInt30();
    _out.writeUInt30(expCount);
    for (int i = 0; i < expCount; i++) {
      _procCanonRef();
    }

    final partCount = _readUInt30();
    _out.writeUInt30(partCount);
    for (int i = 0; i < partCount; i++) {
      _procExpressionList();
      _procStringRef();
    }

    final tdCount = _readUInt30();
    _out.writeUInt30(tdCount);
    for (int i = 0; i < tdCount; i++) {
      _procCanonRef();
      _procUriRef();
      _procOffset();
      _procStringRef();
      _procExpressionList();
      _procTypeParameterList();
      _procDartType();
    }

    final clsCount = _readUInt30();
    assert(clsCount == classCount);
    _out.writeUInt30(clsCount);
    final outClassOffsets = Int32List(clsCount + 1);
    for (int i = 0; i < clsCount; i++) {
      _pos = inClassOffsets[i];
      outClassOffsets[i] = _out.length;
      _procClass(inClassOffsets[i + 1], isLegacyLibrary: isLegacyLibrary);
    }
    _pos = inClassOffsets[clsCount];
    outClassOffsets[clsCount] = _out.length;

    final extCount = _readUInt30();
    _out.writeUInt30(extCount);
    for (int i = 0; i < extCount; i++) {
      _out.writeByte(_readByte()); // Tag.Extension
      _procCanonRef();
      _procStringRef();
      _procExpressionList();
      _procUriRef();
      _procOffset();
      _out.writeByte(_readByte());
      _procTypeParameterList();
      _procDartType();
      final descCount = _readUInt30();
      _out.writeUInt30(descCount);
      for (int j = 0; j < descCount; j++) {
        _procName();
        _out.writeByte(_readByte());
        _out.writeByte(_readByte());
        _procCanonRef();
        _procCanonRef();
      }
    }

    final extTypeCount = _readUInt30();
    _out.writeUInt30(extTypeCount);
    for (int i = 0; i < extTypeCount; i++) {
      _out.writeByte(_readByte()); // Tag.ExtensionTypeDeclaration
      _procCanonRef();
      _procStringRef();
      _procExpressionList();
      _procUriRef();
      _procOffset();
      _out.writeByte(_readByte());
      _procTypeParameterList();
      _procDartType();
      _procStringRef();
      _procDartTypeList();
      final etProcCount = _readUInt30();
      _out.writeUInt30(etProcCount);
      for (int j = 0; j < etProcCount; j++) {
        _procProcedure(-1, keepBody: false);
      }
      final descCount = _readUInt30();
      _out.writeUInt30(descCount);
      for (int j = 0; j < descCount; j++) {
        _procName();
        _out.writeByte(_readByte());
        _out.writeByte(_readByte());
        _procCanonRef();
        _procCanonRef();
      }
    }

    final fieldCount = _readUInt30();
    _out.writeUInt30(fieldCount);
    for (int i = 0; i < fieldCount; i++) {
      _procField(isMixin: false);
    }

    final pCount = _readUInt30();
    assert(pCount == procCount);
    _out.writeUInt30(pCount);
    final outProcOffsets = Int32List(pCount + 1);
    for (int i = 0; i < pCount; i++) {
      _pos = inProcOffsets[i];
      outProcOffsets[i] = _out.length;
      _procProcedure(inProcOffsets[i + 1], keepBody: false);
    }
    _pos = inProcOffsets[pCount];
    outProcOffsets[pCount] = _out.length;

    final sourceRefsOffset = _out.length;
    int usedCount = 0;
    for (int i = 1; i < _sourcesUsedInLibrary.length; i++) {
      if (_sourcesUsedInLibrary[i]) usedCount++;
    }
    _out.writeUInt30(usedCount);
    for (int i = 1; i < _sourcesUsedInLibrary.length; i++) {
      if (_sourcesUsedInLibrary[i]) {
        _out.writeUInt30(i);
        _sourcesUsedInLibrary[i] = false;
      }
    }

    _out.writeUInt32(sourceRefsOffset);
    for (int i = 0; i <= clsCount; i++) {
      _out.writeUInt32(outClassOffsets[i]);
    }
    _out.writeUInt32(clsCount);
    for (int i = 0; i <= pCount; i++) {
      _out.writeUInt32(outProcOffsets[i]);
    }
    _out.writeUInt32(pCount);
  }

  void _procClass(int endOffset, {required bool isLegacyLibrary}) {
    final savedPos = _pos;
    _pos = endOffset - 4;
    final procCount = _readUInt32();
    _pos = endOffset - (procCount + 2) * 4;
    final inProcOffsets = Int32List(procCount + 1);
    for (int i = 0; i <= procCount; i++) {
      inProcOffsets[i] = _readUInt32();
    }
    _pos = savedPos;

    _out.writeByte(_readByte()); // Tag.Class
    _procCanonRef();
    _procUriRef();
    _procOffset();
    _procOffset();
    _procOffset();
    final flags = _readUInt30();
    _out.writeUInt30(flags);
    // Any class that can be used as a mixin must keep its member bodies and
    // field initializers: `mixin` (1 << 4), `mixin class` (1 << 8), and every
    // class in a library whose language version is below 3.0.
    final isMixin = isLegacyLibrary || (flags & ((1 << 4) | (1 << 8))) != 0;
    _procStringRef();
    _procExpressionList();
    _procTypeParameterList();
    _procOptionDartType();
    _procOptionDartType();
    _procDartTypeList();

    final fieldCount = _readUInt30();
    _out.writeUInt30(fieldCount);
    for (int i = 0; i < fieldCount; i++) {
      _procField(isMixin: isMixin);
    }

    final ctorCount = _readUInt30();
    _out.writeUInt30(ctorCount);
    for (int i = 0; i < ctorCount; i++) {
      _procConstructor();
    }

    final pCount = _readUInt30();
    assert(pCount == procCount);
    _out.writeUInt30(pCount);
    final outProcOffsets = Int32List(pCount + 1);
    for (int i = 0; i < pCount; i++) {
      _pos = inProcOffsets[i];
      outProcOffsets[i] = _out.length;
      _procProcedure(inProcOffsets[i + 1], keepBody: isMixin);
    }
    outProcOffsets[pCount] = _out.length;

    for (int i = 0; i <= pCount; i++) {
      _out.writeUInt32(outProcOffsets[i]);
    }
    _out.writeUInt32(pCount);
  }

  void _procField({required bool isMixin}) {
    _out.writeByte(_readByte()); // Tag.Field
    _procCanonRef();
    _procCanonRef();
    _procCanonRef();
    _procUriRef();
    _procOffset();
    _procOffset();
    final flags = _readUInt30();
    _out.writeUInt30(flags);
    final isFinal = (flags & 1) != 0;
    final isConst = (flags & 2) != 0;
    final isStatic = (flags & 4) != 0;
    final keepInit = isConst || isMixin || (isFinal && !isStatic);
    _procName();
    final scopeSize = _readUInt30();
    _out.writeUInt30(keepInit ? scopeSize : 0);
    _procExpressionList();
    _procDartType();
    _procOptionVariable(keepInit: true);
    if (keepInit) {
      _procOptionExpression();
      _procOptionScope(scopeSize);
    } else {
      final prev = _emitting;
      _emitting = false;
      _procOptionExpression();
      _procOptionScope(scopeSize);
      _emitting = prev;
      _out.writeByte(Tag.Nothing);
      _out.writeByte(Tag.Nothing);
    }
  }

  void _procConstructor() {
    _out.writeByte(_readByte()); // Tag.Constructor
    _procCanonRef();
    _procUriRef();
    _procOffset();
    _procOffset();
    _procOffset();
    final flags = _readByte();
    _out.writeByte(flags);
    final isConst = (flags & 1) != 0;
    _procName();
    _procExpressionList();
    _procFunctionNode(-1, keepBody: false);
    final initCount = _readUInt30();
    if (isConst) {
      _out.writeUInt30(initCount);
      for (int i = 0; i < initCount; i++) {
        _procInitializer();
      }
    } else {
      _out.writeUInt30(0);
      final prev = _emitting;
      _emitting = false;
      for (int i = 0; i < initCount; i++) {
        _procInitializer();
      }
      _emitting = prev;
    }
  }

  void _procProcedure(int endOffset, {required bool keepBody}) {
    _out.writeByte(_readByte()); // Tag.Procedure
    _procCanonRef();
    _procUriRef();
    _procOffset();
    _procOffset();
    _procOffset();
    _out.writeByte(_readByte()); // kind
    _out.writeByte(_readByte()); // stubKind
    final flags = _readUInt30(); // flags
    _out.writeUInt30(flags);
    final isConst = (flags & 8) != 0; // Procedure.FlagConst
    _procName();
    _procExpressionList();
    _procCanonRef();
    _procOptionDartType();
    _procFunctionNode(endOffset, keepBody: keepBody || isConst);
  }

  void _procFunctionNode(int outerEndOffset, {required bool keepBody}) {
    _out.writeByte(_readByte()); // Tag.FunctionNode
    _procOffset();
    _procOffset();
    _out.writeByte(_readByte());
    _out.writeByte(_readByte());
    final scopeSize = _readUInt30();
    _out.writeUInt30(keepBody ? scopeSize : 0);
    _procTypeParameterList();
    _procOptionVariable(keepInit: true);
    _out.writeUInt30(_readUInt30());
    _out.writeUInt30(_readUInt30());
    final posCount = _readUInt30();
    _out.writeUInt30(posCount);
    for (int i = 0; i < posCount; i++) {
      _procVariable(keepInit: true);
    }
    final namedCount = _readUInt30();
    _out.writeUInt30(namedCount);
    for (int i = 0; i < namedCount; i++) {
      _procVariable(keepInit: true);
    }
    _procDartType();
    _procOptionDartType();
    final rftTag = _readByte();
    _out.writeByte(rftTag);
    if (rftTag != 0) {
      _procCanonRef();
      final taTag = _readByte();
      _out.writeByte(taTag);
      if (taTag != 0) {
        _procDartTypeList();
      }
      final errTag = _readByte();
      _out.writeByte(errTag);
      if (errTag != 0) {
        _procStringRef();
      }
    }
    if (keepBody) {
      _procOptionStatement();
      _procOptionScope(scopeSize);
      _procOptionCapturedContexts();
    } else {
      if (outerEndOffset > 0 && _emitting) {
        _pos = outerEndOffset;
      } else {
        final prev = _emitting;
        _emitting = false;
        _procOptionStatement();
        _procOptionScope(scopeSize);
        _procOptionCapturedContexts();
        _emitting = prev;
      }
      _out.writeByte(Tag.Nothing);
      _out.writeByte(Tag.Nothing);
      _out.writeByte(Tag.Nothing);
    }
  }

  void _procOptionVariable({required bool keepInit}) {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      _procVariable(keepInit: keepInit);
    }
  }

  void _procVariable({required bool keepInit}) {
    final oldVarOffset = _pos;
    if (_emitting) {
      _varOffsetMap[oldVarOffset] = _out.length;
    }
    _out.writeByte(_readByte());
    _procOffset();
    _procOffset();
    _procExpressionList();
    _out.writeUInt30(_readUInt30());
    _procStringRef();
    _procDartType();
    if (keepInit) {
      _procOptionExpression();
    } else {
      final prev = _emitting;
      _emitting = false;
      _procOptionExpression();
      _emitting = prev;
      _out.writeByte(Tag.Nothing);
    }
  }

  void _procOptionScope(int scopeSize) {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      final count = _readUInt30();
      _out.writeUInt30(count);
      for (int i = 0; i < count; i++) {
        _out.writeByte(_readByte());
        final varCount = _readUInt30();
        _out.writeUInt30(varCount);
        for (int j = 0; j < varCount; j++) {
          _procVariableReference();
        }
      }
    }
  }

  void _procOptionCapturedContexts() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      final count = _readUInt30();
      _out.writeUInt30(count);
      for (int i = 0; i < count; i++) {
        _out.writeUInt30(_readUInt30());
      }
    }
  }

  void _procVariableReference() {
    final oldVarOffset = _readUInt30();
    final idx = _readUInt30();
    _out.writeUInt30(_emitting ? (_varOffsetMap[oldVarOffset] ?? 0) : 0);
    _out.writeUInt30(idx);
  }

  void _procOptionVariableReference() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      _procVariableReference();
    }
  }

  void _procTypeParameterList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _out.writeByte(_readByte());
      _procExpressionList();
      _out.writeByte(_readByte());
      _procStringRef();
      _procDartType();
      _procDartType();
    }
  }

  void _procOptionDartType() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      _procDartType();
    }
  }

  void _procDartTypeList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _procDartType();
    }
  }

  void _procNamedTypeList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _procStringRef();
      _procDartType();
      _out.writeByte(_readByte());
    }
  }

  void _procDartType() {
    final tag = _readByte();
    _out.writeByte(tag);
    switch (tag) {
      case Tag.TypedefType:
        _out.writeByte(_readByte());
        _procCanonRef();
        _procDartTypeList();
      case Tag.InvalidType:
      case Tag.DynamicType:
      case Tag.VoidType:
      case Tag.NullType:
        break;
      case Tag.InterfaceType:
        _out.writeByte(_readByte());
        _procCanonRef();
        _procDartTypeList();
      case Tag.FunctionType:
        _out.writeByte(_readByte());
        _procTypeParameterList();
        _out.writeUInt30(_readUInt30());
        _out.writeUInt30(_readUInt30());
        _procDartTypeList();
        _procNamedTypeList();
        _procDartType();
      case Tag.TypeParameterType:
        _out.writeByte(_readByte());
        _out.writeUInt30(_readUInt30());
      case Tag.SimpleInterfaceType:
        _out.writeByte(_readByte());
        _procCanonRef();
      case Tag.SimpleFunctionType:
        _out.writeByte(_readByte());
        _procDartTypeList();
        _procDartType();
      case Tag.NeverType:
        _out.writeByte(_readByte());
      case Tag.IntersectionType:
        _procDartType();
        _procDartType();
      case Tag.RecordType:
        _out.writeByte(_readByte());
        _procDartTypeList();
        _procNamedTypeList();
      case Tag.ExtensionType:
        _out.writeByte(_readByte());
        _procCanonRef();
        _procDartTypeList();
        _procDartType();
      case Tag.FutureOrType:
        _out.writeByte(_readByte());
        _procDartType();
      default:
        throw StateError('Unexpected DartType tag: $tag at $_pos');
    }
  }

  void _procInitializer() {
    final tag = _readByte();
    _out.writeByte(tag);
    switch (tag) {
      case Tag.InvalidInitializer:
        _procOffset();
        _procStringRef();
        _out.writeByte(_readByte());
      case Tag.FieldInitializer:
        _procOffset();
        _out.writeByte(_readByte());
        _procCanonRef();
        _procExpression();
      case Tag.SuperInitializer:
        _procOffset();
        _out.writeByte(_readByte());
        _procCanonRef();
        _procArguments();
      case Tag.RedirectingInitializer:
        _procOffset();
        _procCanonRef();
        _procArguments();
      case Tag.LocalInitializer:
        _procOffset();
        _procVariable(keepInit: true);
      case Tag.AssertInitializer:
        _procOffset();
        _procStatement();
      default:
        throw StateError('Unexpected Initializer tag: $tag at $_pos');
    }
  }

  void _procArguments() {
    _out.writeUInt30(_readUInt30());
    _procDartTypeList();
    _procExpressionList();
    final namedCount = _readUInt30();
    _out.writeUInt30(namedCount);
    for (int i = 0; i < namedCount; i++) {
      _procStringRef();
      _procExpression();
    }
  }

  void _procOptionExpression() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) {
      _procExpression();
    }
  }

  void _procExpressionList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _procExpression();
    }
  }

  void _procExpression() {
    final tagByte = _readByte();
    _out.writeByte(tagByte);
    final tag =
        (tagByte & Tag.SpecializedTagHighBits) == Tag.SpecializedTagHighBits
        ? (tagByte & Tag.SpecializedTagMask)
        : tagByte;
    switch (tag) {
      case Tag.SpecializedVariableGet:
        _procOffset();
        final oldVarOffset = _readUInt30();
        _out.writeUInt30(_emitting ? (_varOffsetMap[oldVarOffset] ?? 0) : 0);
      case Tag.SpecializedVariableSet:
        _procOffset();
        final oldVarOffset = _readUInt30();
        _out.writeUInt30(_emitting ? (_varOffsetMap[oldVarOffset] ?? 0) : 0);
        _procExpression();
      case Tag.SpecializedIntLiteral:
        _procOffset();
      case Tag.LoadLibrary:
      case Tag.CheckLibraryIsLoaded:
        _procOffset();
        _out.writeUInt30(_readUInt30());
      case Tag.InvalidExpression:
        _procOffset();
        _procStringRef();
        _procOptionExpression();
      case Tag.VariableGet:
        _procOffset();
        _procVariableReference();
        _procOptionDartType();
      case Tag.VariableSet:
        _procOffset();
        _procVariableReference();
        _procExpression();
      case Tag.AbstractSuperPropertyGet:
      case Tag.SuperPropertyGet:
        _procOffset();
        _procExpression();
        _procName();
        _procCanonRef();
        _procCanonRef();
      case Tag.AbstractSuperPropertySet:
      case Tag.SuperPropertySet:
        _procOffset();
        _procExpression();
        _procName();
        _procExpression();
        _procCanonRef();
        _procCanonRef();
      case Tag.StaticGet:
      case Tag.StaticTearOff:
      case Tag.ConstructorTearOff:
      case Tag.RedirectingFactoryTearOff:
        _procOffset();
        _procCanonRef();
      case Tag.StaticSet:
        _procOffset();
        _procCanonRef();
        _procExpression();
      case Tag.AbstractSuperMethodInvocation:
      case Tag.SuperMethodInvocation:
        _procOffset();
        _procExpression();
        _procName();
        _procArguments();
        _procCanonRef();
        _procCanonRef();
      case Tag.StaticInvocation:
      case Tag.ConstStaticInvocation:
      case Tag.ConstructorInvocation:
      case Tag.ConstConstructorInvocation:
        _procOffset();
        _procCanonRef();
        _procArguments();
      case Tag.Not:
      case Tag.NullCheck:
      case Tag.FunctionTearOff:
      case Tag.EqualsNull:
        _procOffset();
        _procExpression();
      case Tag.LogicalExpression:
        _procOffset();
        _procExpression();
        _out.writeByte(_readByte());
        _procExpression();
      case Tag.ConditionalExpression:
        _procOffset();
        _procExpression();
        _procExpression();
        _procExpression();
        _procOptionDartType();
      case Tag.StringConcatenation:
        _procOffset();
        _procExpressionList();
      case Tag.ListConcatenation:
      case Tag.SetConcatenation:
      case Tag.ListLiteral:
      case Tag.ConstListLiteral:
      case Tag.SetLiteral:
      case Tag.ConstSetLiteral:
        _procOffset();
        _procDartType();
        _procExpressionList();
      case Tag.MapConcatenation:
        _procOffset();
        _procDartType();
        _procDartType();
        _procExpressionList();
      case Tag.InstanceCreation:
        _procOffset();
        _procCanonRef();
        _procDartTypeList();
        final fvCount = _readUInt30();
        _out.writeUInt30(fvCount);
        for (int i = 0; i < fvCount; i++) {
          _procCanonRef();
          _procExpression();
        }
        final assertCount = _readUInt30();
        _out.writeUInt30(assertCount);
        for (int i = 0; i < assertCount; i++) {
          _procStatement();
        }
        _procExpressionList();
      case Tag.FileUriExpression:
        _procUriRef();
        _procOffset();
        _procExpression();
      case Tag.IsExpression:
        _procOffset();
        _procExpression();
        _procDartType();
      case Tag.AsExpression:
        _procOffset();
        _out.writeByte(_readByte());
        _procExpression();
        _procDartType();
      case Tag.StringLiteral:
      case Tag.BigIntLiteral:
      case Tag.SymbolLiteral:
        _procOffset();
        _procStringRef();
      case Tag.PositiveIntLiteral:
      case Tag.NegativeIntLiteral:
        _procOffset();
        _out.writeUInt30(_readUInt30());
      case Tag.DoubleLiteral:
        _procOffset();
        _out.writeBytes(_in, _pos, _pos + 8);
        _pos += 8;
      case Tag.TrueLiteral:
      case Tag.FalseLiteral:
      case Tag.NullLiteral:
      case Tag.ThisExpression:
      case Tag.Rethrow:
        _procOffset();
      case Tag.TypeLiteral:
        _procOffset();
        _procDartType();
      case Tag.Throw:
        _procOffset();
        _out.writeByte(_readByte());
        _procExpression();
      case Tag.MapLiteral:
      case Tag.ConstMapLiteral:
        _procOffset();
        _procDartType();
        _procDartType();
        final entryCount = _readUInt30();
        _out.writeUInt30(entryCount);
        for (int i = 0; i < entryCount; i++) {
          _procExpression();
          _procExpression();
        }
      case Tag.RecordLiteral:
      case Tag.ConstRecordLiteral:
        _procOffset();
        _procExpressionList();
        final namedCount = _readUInt30();
        _out.writeUInt30(namedCount);
        for (int i = 0; i < namedCount; i++) {
          _procStringRef();
          _procExpression();
        }
        _procDartType();
      case Tag.AwaitExpression:
        _procOffset();
        _procExpression();
        _procOptionDartType();
      case Tag.FunctionExpression:
        _procOffset();
        _out.writeUInt30(_readUInt30());
        _procFunctionNode(-1, keepBody: true);
      case Tag.Let:
        _procOffset();
        _procVariable(keepInit: true);
        _procExpression();
      case Tag.BlockExpression:
        _procOffset();
        final scopeSize = _readUInt30();
        _out.writeUInt30(scopeSize);
        _procStatementList();
        _procExpression();
        _procOptionScope(scopeSize);
      case Tag.Instantiation:
        _procOffset();
        _procExpression();
        _procDartTypeList();
      case Tag.ConstantExpression:
        _procOffset();
        _procDartType();
        _out.writeUInt30(_remapConst(_readUInt30()));
      case Tag.FileUriConstantExpression:
        _procOffset();
        _procUriRef();
        _procDartType();
        _out.writeUInt30(_remapConst(_readUInt30()));
      case Tag.InstanceGet:
      case Tag.InstanceTearOff:
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procDartType();
        _procCanonRef();
        _procCanonRef();
      case Tag.DynamicGet:
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
      case Tag.RecordIndexGet:
        _procOffset();
        _procExpression();
        _procDartType();
        _out.writeUInt30(_readUInt30());
      case Tag.RecordNameGet:
        _procOffset();
        _procExpression();
        _procDartType();
        _procStringRef();
      case Tag.InstanceSet:
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procExpression();
        _procCanonRef();
        _procCanonRef();
      case Tag.DynamicSet:
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procExpression();
      case Tag.InstanceInvocation:
        _out.writeByte(_readByte());
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procArguments();
        _procDartType();
        _procDartType();
        _procCanonRef();
        _procCanonRef();
      case Tag.InstanceGetterInvocation:
        _out.writeByte(_readByte());
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procArguments();
        _procDartType();
        _procCanonRef();
        _procCanonRef();
      case Tag.DynamicInvocation:
        _out.writeByte(_readByte());
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procName();
        _procArguments();
      case Tag.FunctionInvocation:
        _out.writeByte(_readByte());
        _procOffset();
        _procExpression();
        _procArguments();
        _procDartType();
      case Tag.LocalFunctionInvocation:
        _procOffset();
        _procVariableReference();
        _procArguments();
        _procDartType();
      case Tag.EqualsCall:
        _procOffset();
        _procExpression();
        _procExpression();
        _procDartType();
        _procCanonRef();
        _procCanonRef();
      case Tag.TypedefTearOff:
        _procOffset();
        _procTypeParameterList();
        _procExpression();
        _procDartTypeList();
      case Tag.RedirectingFactoryInvocation:
        _procOffset();
        _procCanonRef();
        _procExpression();
      case Tag.SwitchExpression:
        _procOffset();
        _procExpression();
        _procOptionDartType();
        final caseCount = _readUInt30();
        _out.writeUInt30(caseCount);
        for (int i = 0; i < caseCount; i++) {
          _procOffset();
          _procPatternGuard();
          _procExpression();
        }
        _procOptionDartType();
      case Tag.PatternAssignment:
        _procOffset();
        _procPattern();
        _procExpression();
        _procOptionDartType();
      default:
        throw StateError(
          'Unexpected Expression tag: $tag (byte $tagByte) at $_pos',
        );
    }
  }

  void _procPatternGuard() {
    _procOffset();
    _procPattern();
    _procOptionExpression();
  }

  void _procOptionPattern() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) _procPattern();
  }

  void _procPatternList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _procPattern();
    }
  }

  void _procPattern() {
    final tag = _readByte();
    _out.writeByte(tag);
    switch (tag) {
      case Tag.AndPattern:
        _procOffset();
        _procPattern();
        _procPattern();
      case Tag.AssignedVariablePattern:
        _procOffset();
        _procVariableReference();
        _procOptionVariableReference();
        _procOptionDartType();
        _out.writeByte(_readByte());
      case Tag.CastPattern:
        _procOffset();
        _procPattern();
        _procDartType();
      case Tag.ConstantPattern:
        _procOffset();
        _procExpression();
        _procOptionDartType();
        _procCanonRef();
        _procOptionDartType();
      case Tag.InvalidPattern:
        _procOffset();
        _procExpression();
        final vCount = _readUInt30();
        _out.writeUInt30(vCount);
        for (int i = 0; i < vCount; i++) {
          _procVariable(keepInit: true);
        }
      case Tag.ListPattern:
        _procOffset();
        _procOptionDartType();
        _procPatternList();
        _procOptionDartType();
        _procOptionDartType();
        _out.writeByte(_readByte());
        _procOptionDartType();
        for (int i = 0; i < 5; i++) {
          _procCanonRef();
          _procOptionDartType();
        }
      case Tag.MapPattern:
        _procOffset();
        _procOptionDartType();
        _procOptionDartType();
        final eCount = _readUInt30();
        _out.writeUInt30(eCount);
        for (int i = 0; i < eCount; i++) {
          final eTag = _readByte();
          _out.writeByte(eTag);
          if (eTag == Tag.MapPatternEntry) {
            _procOffset();
            _procExpression();
            _procPattern();
            _procOptionDartType();
          } else {
            _procOffset();
          }
        }
        _procOptionDartType();
        _procOptionDartType();
        _out.writeByte(_readByte());
        _procOptionDartType();
        _procCanonRef();
        _procOptionDartType();
        _procCanonRef();
        _procOptionDartType();
      case Tag.NamedPattern:
        _procOffset();
        _procStringRef();
        _procPattern();
        _procName();
        _out.writeByte(_readByte());
        _procCanonRef();
        _procOptionDartType();
        _procOptionDartType();
        _out.writeUInt30(_readUInt30());
        _procOptionDartType();
        final taTag = _readByte();
        _out.writeByte(taTag);
        if (taTag != 0) _procDartTypeList();
      case Tag.NullAssertPattern:
      case Tag.NullCheckPattern:
        _procOffset();
        _procPattern();
      case Tag.ObjectPattern:
        _procOffset();
        _procDartType();
        _procPatternList();
        _procOptionDartType();
        _out.writeByte(_readByte());
        _procOptionDartType();
      case Tag.OrPattern:
        _procOffset();
        _procPattern();
        _procPattern();
        final jvCount = _readUInt30();
        _out.writeUInt30(jvCount);
        for (int i = 0; i < jvCount; i++) {
          _procVariableReference();
        }
      case Tag.RecordPattern:
        _procOffset();
        _procPatternList();
        _procOptionDartType();
        _procOptionDartType();
        _out.writeByte(_readByte());
        _procOptionDartType();
      case Tag.RelationalPattern:
        _procOffset();
        _out.writeByte(_readByte());
        _procExpression();
        _procOptionDartType();
        _procOptionDartType();
        _out.writeByte(_readByte());
        _procName();
        _procCanonRef();
        final taTag = _readByte();
        _out.writeByte(taTag);
        if (taTag != 0) _procDartTypeList();
        _procOptionDartType();
      case Tag.RestPattern:
        _procOffset();
        _procOptionPattern();
      case Tag.VariablePattern:
        _procOffset();
        _procOptionDartType();
        _procVariable(keepInit: true);
        _procOptionDartType();
      case Tag.WildcardPattern:
        _procOffset();
        _procOptionDartType();
      default:
        throw StateError('Unexpected Pattern tag: $tag at $_pos');
    }
  }

  void _procOptionStatement() {
    final tag = _readByte();
    _out.writeByte(tag);
    if (tag != 0) _procStatement();
  }

  void _procStatementList() {
    final count = _readUInt30();
    _out.writeUInt30(count);
    for (int i = 0; i < count; i++) {
      _procStatement();
    }
  }

  void _procStatement() {
    final tag = _readByte();
    _out.writeByte(tag);
    switch (tag) {
      case Tag.ExpressionStatement:
        _procExpression();
      case Tag.Block:
        _procOffset();
        _procOffset();
        final scopeSize = _readUInt30();
        _out.writeUInt30(scopeSize);
        _procStatementList();
        _procOptionScope(scopeSize);
      case Tag.EmptyStatement:
        break;
      case Tag.AssertStatement:
        _procExpression();
        _procOffset();
        _procOffset();
        _procOptionExpression();
      case Tag.LabeledStatement:
        _procOffset();
        _procStatement();
      case Tag.BreakStatement:
      case Tag.ContinueSwitchStatement:
        _procOffset();
        _out.writeUInt30(_readUInt30());
      case Tag.WhileStatement:
        _procOffset();
        final scopeSize = _readUInt30();
        _out.writeUInt30(scopeSize);
        _procExpression();
        _procStatement();
        _procOptionScope(scopeSize);
      case Tag.DoStatement:
        _procOffset();
        _procStatement();
        _procExpression();
      case Tag.ForStatement:
        _procOffset();
        final scopeSize = _readUInt30();
        _out.writeUInt30(scopeSize);
        final varCount = _readUInt30();
        _out.writeUInt30(varCount);
        for (int i = 0; i < varCount; i++) {
          _procVariableDeclaration();
        }
        _procOptionExpression();
        _procExpressionList();
        _procStatement();
        _procOptionScope(scopeSize);
      case Tag.SwitchStatement:
        _procOffset();
        _out.writeByte(_readByte());
        _procExpression();
        _procOptionDartType();
        final caseCount = _readUInt30();
        _out.writeUInt30(caseCount);
        for (int i = 0; i < caseCount; i++) {
          _procOffset();
          final exprCount = _readUInt30();
          _out.writeUInt30(exprCount);
          for (int j = 0; j < exprCount; j++) {
            _procOffset();
            _procExpression();
          }
          _out.writeByte(_readByte());
          _procStatement();
        }
      case Tag.IfStatement:
        _procOffset();
        _procExpression();
        _procStatement();
        _procStatement();
      case Tag.ReturnStatement:
        _procOffset();
        _procOptionExpression();
      case Tag.TryCatch:
        _procOffset();
        _procStatement();
        _out.writeByte(_readByte());
        final catchCount = _readUInt30();
        _out.writeUInt30(catchCount);
        for (int i = 0; i < catchCount; i++) {
          _procOffset();
          final scopeSize = _readUInt30();
          _out.writeUInt30(scopeSize);
          _procDartType();
          _procOptionVariable(keepInit: true);
          _procOptionVariable(keepInit: true);
          _procStatement();
          _procOptionScope(scopeSize);
        }
      case Tag.TryFinally:
        _procOffset();
        _procStatement();
        _procStatement();
      case Tag.YieldStatement:
        _procOffset();
        _out.writeByte(_readByte());
        _procExpression();
      case Tag.VariableStatement:
        _procOffset();
        _procVariableDeclaration();
      case Tag.VariableDeclaration:
        _procOffset();
        _procOptionCapturedContexts();
        _procVariable(keepInit: true);
      case Tag.FunctionDeclaration:
        _procOffset();
        _procVariable(keepInit: true);
        _out.writeUInt30(_readUInt30());
        _procFunctionNode(-1, keepBody: true);
      case Tag.AsyncForInStatement:
      case Tag.ForInStatement:
        _procOffset();
        _procOffset();
        final scopeSize = _readUInt30();
        _out.writeUInt30(scopeSize);
        _procVariable(keepInit: true);
        _procExpression();
        _procStatement();
        _procOptionScope(scopeSize);
      case Tag.AssertBlock:
        _procStatementList();
      case Tag.IfCaseStatement:
        _procOffset();
        _procExpression();
        _procPatternGuard();
        _procStatement();
        _procOptionStatement();
        _procOptionDartType();
      case Tag.PatternVariableDeclaration:
        _procOffset();
        _procPattern();
        _procExpression();
        _out.writeByte(_readByte());
        _procOptionDartType();
      case Tag.PatternSwitchStatement:
        _procOffset();
        _procExpression();
        _procOptionDartType();
        final caseCount = _readUInt30();
        _out.writeUInt30(caseCount);
        for (int i = 0; i < caseCount; i++) {
          final vCount = _readUInt30();
          _out.writeUInt30(vCount);
          for (int j = 0; j < vCount; j++) {
            _procVariable(keepInit: true);
          }
          final gCount = _readUInt30();
          _out.writeUInt30(gCount);
          for (int j = 0; j < gCount; j++) {
            _procOffset();
            _procPatternGuard();
          }
          _out.writeByte(_readByte());
          _procStatement();
        }
      default:
        throw StateError('Unexpected Statement tag: $tag at $_pos');
    }
  }

  void _procVariableDeclaration() {
    _out.writeByte(_readByte()); // Tag.VariableDeclaration
    _procOffset();
    _procOptionCapturedContexts();
    _procVariable(keepInit: true);
  }

  void _visitConstantChildrenForIndexing() {
    final cTag = _readByte();
    switch (cTag) {
      case ConstantTag.NullConstant:
      case ConstantTag.BoolConstant:
      case ConstantTag.IntConstant:
      case ConstantTag.DoubleConstant:
      case ConstantTag.StringConstant:
      case ConstantTag.SymbolConstant:
      case ConstantTag.StaticTearOffConstant:
      case ConstantTag.ConstructorTearOffConstant:
      case ConstantTag.TypeLiteralConstant:
      case ConstantTag.RedirectingFactoryTearOffConstant:
      case ConstantTag.UnevaluatedConstant:
        break;
      case ConstantTag.MapConstant:
        final prev = _emitting;
        _emitting = false;
        _procDartType();
        _procDartType();
        _emitting = prev;
        final count = _readUInt30();
        for (int i = 0; i < count; i++) {
          _remapConst(_readUInt30());
          _remapConst(_readUInt30());
        }
      case ConstantTag.ListConstant:
      case ConstantTag.SetConstant:
        final prev = _emitting;
        _emitting = false;
        _procDartType();
        _emitting = prev;
        final count = _readUInt30();
        for (int i = 0; i < count; i++) {
          _remapConst(_readUInt30());
        }
      case ConstantTag.InstanceConstant:
        _readUInt30();
        final prev = _emitting;
        _emitting = false;
        _procDartTypeList();
        _emitting = prev;
        final fvCount = _readUInt30();
        for (int i = 0; i < fvCount; i++) {
          _readUInt30();
          _remapConst(_readUInt30());
        }
      case ConstantTag.InstantiationConstant:
        _remapConst(_readUInt30());
      case ConstantTag.TypedefTearOffConstant:
        final prev = _emitting;
        _emitting = false;
        _procTypeParameterList();
        _emitting = prev;
        _remapConst(_readUInt30());
      case ConstantTag.RecordConstant:
        final pCount = _readUInt30();
        for (int i = 0; i < pCount; i++) {
          _remapConst(_readUInt30());
        }
        final nCount = _readUInt30();
        for (int i = 0; i < nCount; i++) {
          _readUInt30();
          _remapConst(_readUInt30());
        }
      default:
        throw StateError('Unexpected ConstantTag: $cTag');
    }
  }

  void _procConstantTableEntry() {
    final cTag = _readByte();
    _out.writeByte(cTag);
    switch (cTag) {
      case ConstantTag.NullConstant:
        break;
      case ConstantTag.BoolConstant:
        _out.writeByte(_readByte());
      case ConstantTag.IntConstant:
        _procExpression();
      case ConstantTag.DoubleConstant:
        _out.writeBytes(_in, _pos, _pos + 8);
        _pos += 8;
      case ConstantTag.StringConstant:
        _procStringRef();
      case ConstantTag.SymbolConstant:
        _procCanonRef();
        _procStringRef();
      case ConstantTag.MapConstant:
        _procDartType();
        _procDartType();
        final count = _readUInt30();
        _out.writeUInt30(count);
        for (int i = 0; i < count; i++) {
          _out.writeUInt30(_remapConst(_readUInt30()));
          _out.writeUInt30(_remapConst(_readUInt30()));
        }
      case ConstantTag.ListConstant:
      case ConstantTag.SetConstant:
        _procDartType();
        final count = _readUInt30();
        _out.writeUInt30(count);
        for (int i = 0; i < count; i++) {
          _out.writeUInt30(_remapConst(_readUInt30()));
        }
      case ConstantTag.InstanceConstant:
        _procCanonRef();
        _procDartTypeList();
        final fvCount = _readUInt30();
        _out.writeUInt30(fvCount);
        for (int i = 0; i < fvCount; i++) {
          _procCanonRef();
          _out.writeUInt30(_remapConst(_readUInt30()));
        }
      case ConstantTag.InstantiationConstant:
        _out.writeUInt30(_remapConst(_readUInt30()));
        _procDartTypeList();
      case ConstantTag.TypedefTearOffConstant:
        _procTypeParameterList();
        _out.writeUInt30(_remapConst(_readUInt30()));
        _procDartTypeList();
      case ConstantTag.StaticTearOffConstant:
      case ConstantTag.ConstructorTearOffConstant:
      case ConstantTag.RedirectingFactoryTearOffConstant:
        _procCanonRef();
      case ConstantTag.TypeLiteralConstant:
        _procDartType();
      case ConstantTag.UnevaluatedConstant:
        _procExpression();
      case ConstantTag.RecordConstant:
        final pCount = _readUInt30();
        _out.writeUInt30(pCount);
        for (int i = 0; i < pCount; i++) {
          _out.writeUInt30(_remapConst(_readUInt30()));
        }
        final nCount = _readUInt30();
        _out.writeUInt30(nCount);
        for (int i = 0; i < nCount; i++) {
          _procStringRef();
          _out.writeUInt30(_remapConst(_readUInt30()));
        }
        _procDartType();
      default:
        throw StateError('Unexpected ConstantTag: $cTag');
    }
  }
}
