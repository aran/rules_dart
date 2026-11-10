package dart

import (
	"flag"
	"slices"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// resolveIn indexes the dart_library `lib` of package `app` at //lib,
// then resolves the imported packages of `r`, declared in Bazel package
// `pkg`, and returns its deps.
func resolveIn(t *testing.T, r *rule.Rule, pkg string, imported ...string) []string {
	t.Helper()
	c := config.New()
	c.Exts["dart_pub_deps_repo"] = "pub_deps"
	c.Exts[keyPackageName] = &directiveValue{Value: "app", File: "BUILD.bazel"}
	rc := &resolve.Configurer{}
	rc.RegisterFlags(flag.NewFlagSet("test", flag.ContinueOnError), "update", c)
	if err := rc.CheckFlags(nil, c); err != nil {
		t.Fatal(err)
	}
	rc.Configure(c, "", nil)

	lang := NewLanguage()
	ix := resolve.NewRuleIndex(func(*rule.Rule, string) resolve.Resolver { return lang })
	f := rule.EmptyFile("lib/BUILD.bazel", "lib")
	lib := rule.NewRule("dart_library", "lib")
	lib.SetAttr("package", "//:pubspec-metadata")
	lib.Insert(f)
	ix.AddRule(c, lib, f)
	ix.Finish()

	is := &importSet{packages: map[string]bool{}}
	for _, p := range imported {
		is.packages[p] = true
	}
	lang.(*dartLang).Resolve(c, ix, nil, r, is, label.New("", pkg, r.Name()))
	return r.AttrStrings("deps")
}

func TestResolveExecutableNamedForPackageDependsOnIt(t *testing.T) {
	for _, kind := range []string{"dart_binary", "dart_test"} {
		got := resolveIn(t, rule.NewRule(kind, "app"), "bin", "app", "path")
		want := []string{"//lib", "@pub_deps//:path"}
		if !slices.Equal(got, want) {
			t.Errorf("%s app: deps %v, want %v", kind, got, want)
		}
	}
}

func TestResolveLibraryDoesNotDependOnPackageItProvides(t *testing.T) {
	for _, tt := range []struct {
		name, metadata string
	}{
		{"app", ""},
		{"lib", "//:pubspec-metadata"},
	} {
		r := rule.NewRule("dart_library", tt.name)
		if tt.metadata != "" {
			r.SetAttr("package", tt.metadata)
		}
		if got := resolveIn(t, r, "lib", "app"); len(got) != 0 {
			t.Errorf("dart_library %q (package %q): deps %v, want none", tt.name, tt.metadata, got)
		}
	}
}

// packageIndex indexes one package, `app`, rooted at //pkg as Gazelle
// generates it: its library, holding lib/a.dart and
// lib/src/model/model.dart, and the library of an annotated source,
// lib/src/model/user.dart.
func packageIndex(t *testing.T) (*config.Config, *resolve.RuleIndex, language.Language) {
	t.Helper()
	c := config.New()
	c.Exts["dart_pub_deps_repo"] = "pub_deps"
	c.Exts[keyPackageName] = &directiveValue{Value: "app", File: "BUILD.bazel"}
	rc := &resolve.Configurer{}
	rc.RegisterFlags(flag.NewFlagSet("test", flag.ContinueOnError), "update", c)
	if err := rc.CheckFlags(nil, c); err != nil {
		t.Fatal(err)
	}
	rc.Configure(c, "", nil)

	lang := NewLanguage()
	ix := resolve.NewRuleIndex(func(*rule.Rule, string) resolve.Resolver { return lang })
	f := rule.EmptyFile("pkg/BUILD.bazel", "pkg")
	for _, l := range []struct {
		name string
		srcs []string
	}{
		{"app", []string{"lib/a.dart", "lib/src/model/model.dart"}},
		{"src/model/user", []string{"lib/src/model/user.dart", ":_src/model/user_combined"}},
	} {
		r := rule.NewRule("dart_library", l.name)
		r.SetAttr("package", ":pubspec-metadata")
		r.SetAttr("srcs", l.srcs)
		r.Insert(f)
		ix.AddRule(c, r, f)
	}
	ix.Finish()
	return c, ix, lang
}

// resolveAgainstPackage resolves, against packageIndex, a rule importing uris (a bare
// package name, or a file's `package:` URI).
func resolveAgainstPackage(t *testing.T, kind, pkg, name string, uris ...string) []string {
	t.Helper()
	c, ix, lang := packageIndex(t)
	r := rule.NewRule(kind, name)
	if kind == "dart_library" {
		r.SetAttr("package", ":pubspec-metadata")
		r.SetAttr("srcs", []string{"lib/a.dart", "lib/src/model/model.dart"})
	}
	is := &importSet{packages: map[string]bool{}, uris: map[string]map[string]bool{}}
	for _, u := range uris {
		p := strings.SplitN(strings.TrimPrefix(u, "package:"), "/", 2)[0]
		is.packages[p] = true
		if strings.Contains(u, "/") {
			if is.uris[p] == nil {
				is.uris[p] = map[string]bool{}
			}
			is.uris[p][u] = true
		}
	}
	lang.(*dartLang).Resolve(c, ix, nil, r, is, label.New("", pkg, name))
	return r.AttrStrings("deps")
}

func TestResolvePackageByFile(t *testing.T) {
	for _, tt := range []struct {
		desc, kind, pkg, name string
		uris                  []string
		want                  []string
	}{
		{
			"the package's library to an annotated source's, never itself",
			"dart_library", "pkg", "app",
			[]string{"package:app/a.dart", "package:app/src/model/model.dart", "package:app/src/model/user.dart"},
			[]string{":src/model/user"},
		},
		{
			"an own-package file no rule holds is never a dep",
			"dart_library", "pkg", "app",
			[]string{"package:app/src/model/user.g.dart"},
			nil,
		},
		{
			"test to the rule holding each imported file, pub by package",
			"dart_test", "pkg/test", "app_test",
			[]string{"package:app/a.dart", "package:app/src/model/user.dart", "package:path/path.dart"},
			[]string{"//pkg:app", "//pkg:src/model/user", "@pub_deps//:path"},
		},
		{
			"a file no rule holds falls back to the package",
			"dart_binary", "pkg/bin", "main",
			[]string{"package:app/missing.dart"},
			[]string{"//pkg:app"},
		},
	} {
		got := resolveAgainstPackage(t, tt.kind, tt.pkg, tt.name, tt.uris...)
		if !slices.Equal(got, tt.want) {
			t.Errorf("%s: deps %v, want %v", tt.desc, got, tt.want)
		}
	}
}

func TestPackageLibraryIndexedByFile(t *testing.T) {
	c, _, _ := packageIndex(t)
	r := rule.NewRule("dart_library", "app")
	r.SetAttr("package", ":pubspec-metadata")
	r.SetAttr("srcs", []string{"lib/path.dart", "lib/src/x.dart", ":_gen", "//other:x"})
	var got []string
	for _, s := range (&dartLang{}).importSpecs(c, r, "pkg") {
		got = append(got, s.Imp)
	}
	want := []string{"app", "package:app/path.dart", "package:app/src/x.dart"}
	if !slices.Equal(got, want) {
		t.Errorf("specs %v, want %v", got, want)
	}
}
