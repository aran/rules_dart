package dart

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
)

// agreementErrors runs checkAgreement over the directory rel of a repository
// whose package root `pkg` has the given pubspec ("" for none), with the
// given declaration and directives in force.
func agreementErrors(t *testing.T, rel, pubspec string, decl *packageDecl, directives map[string]string) []string {
	t.Helper()
	repo := t.TempDir()
	if pubspec != "" {
		if err := os.MkdirAll(filepath.Join(repo, "pkg"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(repo, "pkg", "pubspec.yaml"), []byte(pubspec), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c := config.New()
	c.RepoRoot = repo
	if decl != nil {
		c.Exts[extKeyPackageDecl] = decl
	}
	for k, v := range directives {
		c.Exts[k] = &directiveValue{Value: v, File: "pkg/BUILD.bazel"}
	}
	d := &dartLang{}
	d.checkAgreement(language.GenerateArgs{Config: c, Rel: rel})
	var errs []string
	for e := range d.errs.errors {
		errs = append(errs, e)
	}
	sort.Strings(errs)
	return errs
}

func TestAgreement(t *testing.T) {
	const pubspec = "name: from_pubspec\nenvironment:\n  sdk: ^3.13.0\n"
	// A declaration whose attributes are marked `# keep`; Gazelle rewrites
	// one whose are not, so it never disagrees.
	decl := func(name, version string) *packageDecl {
		return &packageDecl{Rel: "pkg", Name: metadataName, PackageName: name, LanguageVersion: version, KeepName: true, KeepVersion: true}
	}
	for _, tt := range []struct {
		name       string
		rel        string
		pubspec    string
		decl       *packageDecl
		directives map[string]string
		// Each wanted error, as words it contains: both values, both places.
		want [][]string
	}{
		{name: "pubspec alone", rel: "pkg", pubspec: pubspec},
		{
			name: "declaration agrees with pubspec", rel: "pkg", pubspec: pubspec,
			decl: decl("from_pubspec", "3.13"),
		},
		{
			name: "directives agree with pubspec", rel: "pkg/lib", pubspec: pubspec,
			directives: map[string]string{keyPackageName: "from_pubspec", keyLanguageVersion: "3.13"},
		},
		{
			name: "directives without a pubspec", rel: "pkg",
			directives: map[string]string{keyPackageName: "x", keyLanguageVersion: "3.13"},
		},
		{
			name: "declaration not kept, differing from pubspec", rel: "pkg", pubspec: pubspec,
			decl: &packageDecl{Rel: "pkg", Name: metadataName, PackageName: "from_decl", LanguageVersion: "3.10"},
		},
		{
			name: "name: declaration and pubspec", rel: "pkg", pubspec: pubspec,
			decl: decl("from_decl", "3.13"),
			want: [][]string{{"package name", `"from_decl"`, "//pkg:pubspec-metadata", `"from_pubspec"`, "pkg/pubspec.yaml"}},
		},
		{
			name: "name: declaration and directive", rel: "pkg",
			decl:       decl("from_decl", ""),
			directives: map[string]string{keyPackageName: "from_directive"},
			want:       [][]string{{"package name", `"from_decl"`, "//pkg:pubspec-metadata", `"from_directive"`, "gazelle:dart_package_name` in pkg/BUILD.bazel"}},
		},
		{
			name: "name: directive and pubspec", rel: "pkg/lib/src", pubspec: pubspec,
			directives: map[string]string{keyPackageName: "from_directive"},
			want:       [][]string{{"package name", `"from_directive"`, "gazelle:dart_package_name", `"from_pubspec"`, "pkg/pubspec.yaml"}},
		},
		{
			name: "version: declaration and pubspec", rel: "pkg/lib/src", pubspec: pubspec,
			decl: decl("from_pubspec", "3.10"),
			want: [][]string{{"language version", `"3.10"`, "//pkg:pubspec-metadata", `"3.13"`, "pkg/pubspec.yaml"}},
		},
		{
			name: "version: a declaration stating none, and a pubspec", rel: "pkg", pubspec: pubspec,
			decl: decl("from_pubspec", ""),
			want: [][]string{{"language version", "none by dart_package_metadata //pkg:pubspec-metadata (`# keep`)", `"3.13"`, "pkg/pubspec.yaml"}},
		},
		{
			name: "version: declaration and directive", rel: "pkg",
			decl:       decl("x", "3.10"),
			directives: map[string]string{keyLanguageVersion: "3.13"},
			want:       [][]string{{"language version", `"3.10"`, "//pkg:pubspec-metadata", `"3.13"`, "gazelle:dart_language_version"}},
		},
		{
			name: "version: directive and pubspec", rel: "pkg/test", pubspec: pubspec,
			directives: map[string]string{keyLanguageVersion: "3.10"},
			want:       [][]string{{"language version", `"3.10"`, "gazelle:dart_language_version", `"3.13"`, "pkg/pubspec.yaml"}},
		},
		{
			// The innermost pubspec roots every directory below it, sub/lib/
			// and tool/ as much as lib/.
			name: "name: directive and the pubspec above", rel: "pkg/sub/lib", pubspec: pubspec,
			directives: map[string]string{keyPackageName: "sub"},
			want:       [][]string{{"package name", `"sub"`, "gazelle:dart_package_name", `"from_pubspec"`, "pkg/pubspec.yaml"}},
		},
		{
			// Any name is the package's declaration.
			name: "a declaration under another name", rel: "pkg", pubspec: pubspec,
			decl: &packageDecl{Rel: "pkg", Name: "pubspec", PackageName: "from_pubspec"},
		},
		{
			name: "two declarations at the root", rel: "pkg", pubspec: pubspec,
			decl: &packageDecl{Rel: "pkg", Name: "pubspec", PackageName: "from_pubspec", Others: []string{"again"}},
			want: [][]string{{"more than one dart_package_metadata", "pubspec, again"}},
		},
		{
			// Reported once, at the root, not again for each directory below.
			name: "two declarations, below the root", rel: "pkg/test", pubspec: pubspec,
			decl: &packageDecl{Rel: "pkg", Name: "pubspec", PackageName: "from_pubspec", Others: []string{"again"}},
		},
		{
			name: "directive agrees with the pubspec above", rel: "pkg/tool", pubspec: pubspec,
			directives: map[string]string{keyPackageName: "from_pubspec"},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got := agreementErrors(t, tt.rel, tt.pubspec, tt.decl, tt.directives)
			if len(got) != len(tt.want) {
				t.Fatalf("got %d errors, want %d: %q", len(got), len(tt.want), got)
			}
			for i, words := range tt.want {
				for _, w := range words {
					if !strings.Contains(got[i], w) {
						t.Errorf("error %q does not name %q", got[i], w)
					}
				}
			}
		})
	}
}

func TestScopePackageFacts(t *testing.T) {
	for _, tt := range []struct {
		rel  string
		kept bool
	}{
		// Within the package that states it, a directive holds.
		{"pkg/tool", true},
		{"pkg/lib/src", true},
		// A package rooted below, by a pubspec or by the layout, has its own.
		{"pkg/example", false},
		{"greet", false},
	} {
		c := repoWithPubspecs(t, "pkg", "pkg/example")
		c.Exts[keyPackageName] = &directiveValue{Value: "app", File: "pkg/BUILD.bazel"}
		c.Exts[keyLanguageVersion] = &directiveValue{Value: "3.12", File: "pkg/BUILD.bazel"}
		scopePackageFacts(c, tt.rel)
		for _, key := range []string{keyPackageName, keyLanguageVersion} {
			if got := directiveFact(c, key) != nil; got != tt.kept {
				t.Errorf("at %s, %s kept = %v, want %v", tt.rel, key, got, tt.kept)
			}
		}
	}
}

func TestNaturalLess(t *testing.T) {
	ordered := []string{"a/build.yaml:1: x", "a/build.yaml:9: x", "a/build.yaml:13: x", "a/build.yaml:13: y", "b"}
	for i := range ordered {
		for j := range ordered {
			if got := naturalLess(ordered[i], ordered[j]); got != (i < j) {
				t.Errorf("naturalLess(%q, %q) = %v", ordered[i], ordered[j], got)
			}
		}
	}
}
