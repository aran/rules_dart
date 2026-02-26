package dart

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTempDart(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "test.dart")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestParseDartFile(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    []DartImport
	}{
		{
			name:  "PlainPackageImport",
			input: `import 'package:foo/foo.dart';`,
			want: []DartImport{
				{URI: "package:foo/foo.dart", IsPackage: true, Package: "foo", Path: "foo.dart"},
			},
		},
		{
			name:  "RelativeImport",
			input: `import 'helper.dart';`,
			want: []DartImport{
				{URI: "helper.dart", IsRelative: true, Path: "helper.dart"},
			},
		},
		{
			name:  "DartSDKImport",
			input: `import 'dart:async';`,
			want: []DartImport{
				{URI: "dart:async", IsDartSDK: true},
			},
		},
		{
			name:  "SingleLineConditional",
			input: `import 'stub.dart' if (dart.library.io) 'io.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io.dart", IsRelative: true, Path: "io.dart"},
			},
		},
		{
			name:  "SingleLineConditionalPackages",
			input: `import 'package:a/a.dart' if (dart.library.io) 'package:b/b.dart';`,
			want: []DartImport{
				{URI: "package:a/a.dart", IsPackage: true, Package: "a", Path: "a.dart"},
				{URI: "package:b/b.dart", IsPackage: true, Package: "b", Path: "b.dart"},
			},
		},
		{
			name: "MultilineConditional",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart'
    if (dart.library.js_interop) 'web_impl.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
				{URI: "web_impl.dart", IsRelative: true, Path: "web_impl.dart"},
			},
		},
		{
			name: "MultilineConditionalExport",
			input: `export 'stub.dart'
    if (dart.library.io) 'io_impl.dart';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
			},
		},
		{
			name: "ConditionalWithTrailingModifier",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart'
    show PlatformClient;`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
			},
		},
		{
			name: "ConditionalThenPlainImport",
			input: `import 'stub.dart'
    if (dart.library.io) 'io_impl.dart';
import 'dart:async';`,
			want: []DartImport{
				{URI: "stub.dart", IsRelative: true, Path: "stub.dart"},
				{URI: "io_impl.dart", IsRelative: true, Path: "io_impl.dart"},
				{URI: "dart:async", IsDartSDK: true},
			},
		},
		{
			name: "MixedImports",
			input: `import 'dart:io';
import 'package:foo/foo.dart';
import 'helper.dart';
import 'package:native_helpers/helpers.dart'
    if (dart.library.js_interop) 'package:web_helpers/helpers.dart';`,
			want: []DartImport{
				{URI: "dart:io", IsDartSDK: true},
				{URI: "package:foo/foo.dart", IsPackage: true, Package: "foo", Path: "foo.dart"},
				{URI: "helper.dart", IsRelative: true, Path: "helper.dart"},
				{URI: "package:native_helpers/helpers.dart", IsPackage: true, Package: "native_helpers", Path: "helpers.dart"},
				{URI: "package:web_helpers/helpers.dart", IsPackage: true, Package: "web_helpers", Path: "helpers.dart"},
			},
		},
		{
			name:  "EmptyFile",
			input: "",
			want:  nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeTempDart(t, tt.input)
			got, err := ParseDartFile(path)
			if err != nil {
				t.Fatalf("ParseDartFile() error = %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("ParseDartFile() returned %d imports, want %d\ngot:  %+v\nwant: %+v", len(got), len(tt.want), got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("import[%d] = %+v, want %+v", i, got[i], tt.want[i])
				}
			}
		})
	}
}
