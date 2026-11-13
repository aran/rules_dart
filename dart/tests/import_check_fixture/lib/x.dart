// A library nothing executable reaches. Its imports are sound, so the root
// build stays green; that its import check exists is what the test asks
// (`e2e/examples/fixtures/analysis_failure/import_check` shows the check
// refusing).
import 'dart:core';
