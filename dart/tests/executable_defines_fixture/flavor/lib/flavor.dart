/// Read when this library's module is compiled, in the environment of the
/// executable that depends on it.
const String appFlavor = String.fromEnvironment(
  'APP_FLAVOR',
  defaultValue: 'unset',
);

const String greeting = String.fromEnvironment(
  'GREETING',
  defaultValue: 'unset',
);
