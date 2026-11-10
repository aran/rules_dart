package dart

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
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
		// A package's hook/ directory, but not one in its test tree or lib/,
		// nor one under hook/.
		{"hook", "hook", ""},
		{"pkg/hook", "hook", "pkg"},
		{"pkg/test/hook", "test", "pkg"},
		{"pkg/lib/hook", "", ""},
		{"pkg/hook/src", "", ""},
	} {
		dir, root := layoutOf(tt.rel)
		if dir != tt.dir || root != tt.root {
			t.Errorf("layoutOf(%q) = %q, %q, want %q, %q", tt.rel, dir, root, tt.dir, tt.root)
		}
	}
}

// repoWithPubspecs is a repository with a pubspec.yaml in each directory
// given, and the config of its root.
func repoWithPubspecs(t *testing.T, dirs ...string) *config.Config {
	t.Helper()
	repo := t.TempDir()
	for _, d := range dirs {
		dir := filepath.Join(repo, filepath.FromSlash(d))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "pubspec.yaml"), []byte("name: x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c := config.New()
	c.RepoRoot = repo
	return c
}

func TestPlaceOf(t *testing.T) {
	c := repoWithPubspecs(t, "pkg", "pkg/example")
	for _, tt := range []struct{ rel, root, layout string }{
		// The innermost pubspec.yaml roots every directory below it.
		{"pkg", "pkg", ""},
		{"pkg/tool", "pkg", ""},
		{"pkg/tool/sub/bin", "pkg", ""},
		{"pkg/benchmark", "pkg", ""},
		{"pkg/lib/src", "pkg", "lib"},
		{"pkg/lib/src/lib", "pkg", "lib"},
		{"pkg/bin", "pkg", "bin"},
		{"pkg/test/bin", "pkg", "test"},
		{"pkg/hook", "pkg", "hook"},
		{"pkg/hook/src", "pkg", ""},
		{"pkg/example", "pkg/example", ""},
		{"pkg/example/bin", "pkg/example", "bin"},
		// With none at or above, the layout places a directory.
		{"", "", ""},
		{"greet", "greet", ""},
		{"greet/tool", "greet/tool", ""},
		{"greet/lib/src", "greet", "lib"},
		{"greet/test/unit", "greet", "test"},
		{"greet/hook", "greet", "hook"},
	} {
		if got := placeOf(c, tt.rel); got.Err != nil || got.Root != tt.root || got.Layout != tt.layout {
			t.Errorf("placeOf(%q) = %+v, want root %q layout %q", tt.rel, got, tt.root, tt.layout)
		}
	}
	if got := placeOf(c, "greet/lib/src/lib"); got.Err == nil {
		t.Errorf("placeOf(greet/lib/src/lib) = %+v, want an ambiguity error", got)
	}

	// A `dart_package_metadata` roots a package as a pubspec.yaml does, and
	// the innermost of the two wins.
	c.Exts[extKeyPackageDecl] = &packageDecl{Rel: "pkg/vendored", Name: "pubspec-metadata"}
	for _, tt := range []struct{ rel, root string }{
		{"pkg/vendored", "pkg/vendored"},
		{"pkg/vendored/tool", "pkg/vendored"},
		{"greet/tool", "greet/tool"},
	} {
		if got := placeOf(c, tt.rel); got.Err != nil || got.Root != tt.root {
			t.Errorf("with metadata at pkg/vendored, placeOf(%q) = %+v, want root %q", tt.rel, got, tt.root)
		}
	}

	// A pubspec.yaml at the repository's root roots the whole repository.
	c = repoWithPubspecs(t, "")
	if got := placeOf(c, "tool"); got.Root != "" || got.Layout != "" {
		t.Errorf("placeOf(tool) = %+v, want the repository root", got)
	}

	// A package rooted inside another's lib/ is refused, as dart_library
	// refuses it.
	c = repoWithPubspecs(t, "pkg", "pkg/lib/inner")
	if got := placeOf(c, "pkg/lib/inner/lib"); got.Err == nil {
		t.Errorf("placeOf(pkg/lib/inner/lib) = %+v, want an error", got)
	}
}
