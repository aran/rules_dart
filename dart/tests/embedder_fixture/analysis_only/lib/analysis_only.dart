import 'dart:fake';

/// Reads the embedder's library through an analysis-only dependency, as a
/// `flutter_library` reads `dart:ui`.
int analysisOnly() => fakeAnswer();
