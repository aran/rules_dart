// FFI types whose layout dependents read from the members the VM's FFI
// transform generates here.
import 'dart:ffi';

final class Point extends Struct {
  @Int32()
  external int x;

  @Double()
  external double y;

  @Array(4)
  external Array<Uint8> bytes;

  int sum() => x + bytes[0];
}

final class Num extends Union {
  @Int64()
  external int i;

  @Float()
  external double f;
}

@AbiSpecificIntegerMapping({
  Abi.androidArm: Int32(),
  Abi.androidArm64: Int64(),
  Abi.androidIA32: Int32(),
  Abi.androidX64: Int64(),
  Abi.androidRiscv64: Int64(),
  Abi.fuchsiaArm64: Int64(),
  Abi.fuchsiaX64: Int64(),
  Abi.fuchsiaRiscv64: Int64(),
  Abi.iosArm: Int32(),
  Abi.iosArm64: Int64(),
  Abi.iosX64: Int64(),
  Abi.linuxArm: Int32(),
  Abi.linuxArm64: Int64(),
  Abi.linuxIA32: Int32(),
  Abi.linuxX64: Int64(),
  Abi.linuxRiscv32: Int32(),
  Abi.linuxRiscv64: Int64(),
  Abi.macosArm64: Int64(),
  Abi.macosX64: Int64(),
  Abi.windowsArm64: Int32(),
  Abi.windowsIA32: Int32(),
  Abi.windowsX64: Int32(),
})
final class MyLong extends AbiSpecificInteger {
  const MyLong();
}

@Packed(1)
final class Packed1 extends Struct {
  @Int8()
  external int a;

  @Int64()
  external int b;
}

final class WithLong extends Struct {
  @MyLong()
  external int l;

  external Point p;
}

final class Handle extends Opaque {}

@Native<Int32 Function(Int32)>(symbol: 'outline_fixture_twice')
external int twice(int x);

int helper() => 41;
