package dart

import (
	"testing"
)

func TestPlaceDir(t *testing.T) {
	for _, tt := range []struct {
		rel   string
		root  string
		split bool
	}{
		{"", "", false},
		{"pkg", "pkg", false},
		{"pkg/tool", "pkg/tool", false},
		{"lib", "", false},
		{"pkg/lib", "pkg", false},
		{"pkg/lib/src", "pkg", true},
		{"pkg/lib/src/model", "pkg", true},
		{"lib/src/model", "", true},
	} {
		got := placeDir(tt.rel)
		if got.Err != nil || got.Root != tt.root || got.Split != tt.split {
			t.Errorf("placeDir(%q) = %+v, want root %q split %v", tt.rel, got, tt.root, tt.split)
		}
	}
	for _, rel := range []string{"pkg/lib/src/lib", "lib/lib", "a/lib/b/lib/c"} {
		if got := placeDir(rel); got.Err == nil {
			t.Errorf("placeDir(%q) = %+v, want an ambiguity error", rel, got)
		}
	}
}

func TestImportedURI(t *testing.T) {
	const file = "pkg/lib/src/model/model.dart"
	for _, tt := range []struct {
		imp  DartImport
		want string
	}{
		{DartImport{URI: "package:other/x.dart", IsPackage: true, Package: "other", Path: "x.dart"}, "package:other/x.dart"},
		{DartImport{URI: "../util/util.dart", IsRelative: true}, "package:app/src/util/util.dart"},
		{DartImport{URI: "model_parts.dart", IsRelative: true}, "package:app/src/model/model_parts.dart"},
		// Leaves lib/: no package: URI reaches it.
		{DartImport{URI: "../../../test/helper.dart", IsRelative: true}, ""},
		{DartImport{URI: "dart:io", IsDartSDK: true}, ""},
	} {
		if got := importedURI("app", "pkg", file, tt.imp); got != tt.want {
			t.Errorf("importedURI(%q) = %q, want %q", tt.imp.URI, got, tt.want)
		}
	}
}

func TestLayoutOf(t *testing.T) {
	for _, tt := range []struct {
		rel, dir, root string
	}{
		{"", "", ""},
		{"bin", "bin", ""},
		{"test", "test", ""},
		{"test/unit", "test", ""},
		{"pkg/bin", "bin", "pkg"},
		{"pkg/test/unit", "test", "pkg"},
		{"pkg/tool/bin", "bin", "pkg/tool"},
		// The nearest component decides: a package named `test` or `bin`.
		{"pkgs/test/bin", "bin", "pkgs/test"},
		{"pkgs/bin/test", "test", "pkgs/bin"},
		// Inside a lib/, a directory is a library directory.
		{"pkg/lib/test", "", ""},
		{"lib/src/bin", "", ""},
		{"pkg", "", ""},
		{"pkg/tool", "", ""},
	} {
		dir, root := layoutOf(tt.rel)
		if dir != tt.dir || root != tt.root {
			t.Errorf("layoutOf(%q) = %q, %q, want %q, %q", tt.rel, dir, root, tt.dir, tt.root)
		}
	}
}

func TestPackageRootOf(t *testing.T) {
	for _, tt := range []struct{ rel, root string }{
		{"", ""},
		{"lib", ""},
		{"bin", ""},
		{"pkg", "pkg"},
		{"pkg/lib/src", "pkg"},
		{"pkg/bin", "pkg"},
		{"pkg/test/unit", "pkg"},
	} {
		if got, err := packageRootOf(tt.rel); err != nil || got != tt.root {
			t.Errorf("packageRootOf(%q) = %q, %v, want %q", tt.rel, got, err, tt.root)
		}
	}
}
