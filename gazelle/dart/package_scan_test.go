package dart

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
)

func TestScanGroupsLibCycles(t *testing.T) {
	root := t.TempDir()
	for file, content := range map[string]string{
		"pkg/pubspec.yaml":          "name: app\n",
		"pkg/lib/app.dart":          "import 'src/x/x.dart';\n",
		"pkg/lib/src/x/x.dart":      "import '../y/y.dart';\n",
		"pkg/lib/src/y/y.dart":      "import 'package:app/src/x/x.dart';\nimport 'package:app/src/z/deep/z.dart';\n",
		"pkg/lib/src/z/deep/z.dart": "import 'package:app/src/w/w.dart';\n",
		"pkg/lib/src/w/w.dart":      "import '../z/deep/z.dart';\n",
		"pkg/lib/src/v/v.dart":      "import 'package:other/other.dart';\npart 'p/p.dart';\n",
		"pkg/lib/src/v/p/p.dart":    "part of '../v.dart';\n",
	} {
		p := filepath.Join(root, file)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c := config.New()
	c.RepoRoot = root
	scan := (&scanState{}).scanOf(c, "pkg")
	for dir, want := range map[string]*libGroup{
		"pkg/lib":            nil,
		"pkg/lib/src/v":      {Owner: "pkg/lib/src/v", Members: []string{"pkg/lib/src/v", "pkg/lib/src/v/p"}},
		"pkg/lib/src/v/p":    {Owner: "pkg/lib/src/v", Members: []string{"pkg/lib/src/v", "pkg/lib/src/v/p"}},
		"pkg/lib/src/x":      {Owner: "pkg/lib/src/x", Members: []string{"pkg/lib/src/x", "pkg/lib/src/y"}},
		"pkg/lib/src/y":      {Owner: "pkg/lib/src/x", Members: []string{"pkg/lib/src/x", "pkg/lib/src/y"}},
		"pkg/lib/src/w":      {Owner: "pkg/lib/src/w", Members: []string{"pkg/lib/src/w", "pkg/lib/src/z/deep"}},
		"pkg/lib/src/z/deep": {Owner: "pkg/lib/src/w", Members: []string{"pkg/lib/src/w", "pkg/lib/src/z/deep"}},
	} {
		got := scan.groups[dir]
		switch {
		case want == nil && got != nil:
			t.Errorf("%s: in cycle %v, want none", dir, got.Members)
		case want != nil && (got == nil || got.Owner != want.Owner || !slices.Equal(got.Members, want.Members)):
			t.Errorf("%s: group %+v, want %+v", dir, got, want)
		}
	}
}

func TestStronglyConnected(t *testing.T) {
	got := stronglyConnected([]string{"a", "b", "c", "d"}, map[string][]string{
		"a": {"b"}, "b": {"c"}, "c": {"a", "d"},
	})
	if len(got) != 2 || len(got[0]) != 1 || got[0][0] != "d" || len(got[1]) != 3 {
		t.Errorf("components %v, want [[d] [a b c]]", got)
	}
}
