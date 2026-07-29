// Minimal translation unit so `cc_shared_library` has something to link.
// Exists only to give `dart_code_asset`'s attribute-validation tests a real
// `CcSharedLibraryInfo` target to point at.
extern "C" int rules_dart_test_symbol(void) {
  return 0;
}
