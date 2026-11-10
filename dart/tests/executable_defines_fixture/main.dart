import 'package:executable_defines_flavor/flavor.dart' as dep;

/// Prints the environment as the dependency's module read it, then as this
/// entrypoint reads it.
void main() {
  const entryFlavor = String.fromEnvironment(
    'APP_FLAVOR',
    defaultValue: 'unset',
  );
  const entryGreeting = String.fromEnvironment(
    'GREETING',
    defaultValue: 'unset',
  );
  print('${dep.appFlavor} ${dep.greeting} $entryFlavor $entryGreeting');
}
