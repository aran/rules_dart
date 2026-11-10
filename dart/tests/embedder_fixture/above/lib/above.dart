import 'dart:fake';

import 'package:analysis_only_user/analysis_only.dart';

/// Reads the embedder's library and a library summarized against it.
int above() => analysisOnly() + fakeAnswer();
