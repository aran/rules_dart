// The dependency half of the fixture, with a violation of its own. It is
// staged for the entrypoint to resolve against but is `:dep`'s file, so its
// absence from the changes is what says the fixes touch only their target's
// own files.
String binLabel() {
  var label = 'bin';
  return label;
}
