package dart

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
)

func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for file, content := range files {
		p := filepath.Join(root, file)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// The whole of lib/ is the package's, whatever its directories and import
// cycles; an annotated source's annotations are recorded, and only the files
// its codegen produces are dropped.
func TestScanHoldsAllOfLib(t *testing.T) {
	root := writeTree(t, map[string]string{
		"pkg/pubspec.yaml":            "name: app\n",
		"pkg/lib/app.dart":            "import 'src/x/x.dart';\n",
		"pkg/lib/src/x/x.dart":        "import '../y/y.dart';\n",
		"pkg/lib/src/y/y.dart":        "import 'package:app/src/x/x.dart';\n",
		"pkg/lib/src/m/user.dart":     "import 'package:json_annotation/json_annotation.dart';\npart 'user.g.dart';\n@JsonSerializable()\nclass User {}\n",
		"pkg/lib/src/m/user.g.dart":   "part of 'user.dart';\n",
		"pkg/lib/src/m/other.g.dart":  "// checked in, and no target here produces it\n",
		"pkg/lib/.hidden/h.dart":      "",
		"pkg/lib/nested/MODULE.bazel": "",
		"pkg/lib/nested/n.dart":       "",
	})
	c := config.New()
	c.RepoRoot = root
	builderRegistryOf(c)
	scan := (&scanState{list: osDir(root)}).scanOf(c, "pkg")
	var got []string
	for _, f := range scan.lib {
		got = append(got, f.Path)
	}
	want := []string{
		"pkg/lib/app.dart",
		"pkg/lib/src/m/other.g.dart",
		"pkg/lib/src/m/user.dart",
		"pkg/lib/src/x/x.dart",
		"pkg/lib/src/y/y.dart",
	}
	if !slices.Equal(got, want) {
		t.Errorf("lib %v, want %v", got, want)
	}
	if anns := scan.annotated["pkg/lib/src/m/user.dart"]; !slices.Equal(anns, []string{"JsonSerializable"}) {
		t.Errorf("annotations of user.dart %v, want [JsonSerializable]", anns)
	}
}

func TestLibStem(t *testing.T) {
	for in, want := range map[string]string{
		"lib/user.dart":           "user",
		"lib/src/model/user.dart": "src/model/user",
	} {
		if got := libStem(in); got != want {
			t.Errorf("libStem(%q) = %q, want %q", in, got, want)
		}
	}
}
