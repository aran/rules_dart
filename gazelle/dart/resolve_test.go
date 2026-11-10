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

// resolveIn indexes the dart_library `lib` (package_name `app`) at //lib,
// then resolves the imported packages of `r`, declared in Bazel package
// `pkg`, and returns its deps.
func resolveIn(t *testing.T, r *rule.Rule, pkg string, imported ...string) []string {
	t.Helper()
	c := config.New()
	c.Exts["dart_pub_deps_repo"] = "pub_deps"
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
	lib.SetAttr("package_name", "app")
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
		name, packageName string
	}{
		{"app", ""},
		{"lib", "app"},
	} {
		r := rule.NewRule("dart_library", tt.name)
		if tt.packageName != "" {
			r.SetAttr("package_name", tt.packageName)
		}
		if got := resolveIn(t, r, "lib", "app"); len(got) != 0 {
			t.Errorf("dart_library %q (package_name %q): deps %v, want none", tt.name, tt.packageName, got)
		}
	}
}

// splitIndex indexes one package, `app`, rooted at //pkg and split over
// //pkg/lib (a.dart), //pkg/lib/src/model (model.dart) and
// //pkg/lib/src/util (util.dart), as Gazelle generates it.
func splitIndex(t *testing.T) (*config.Config, *resolve.RuleIndex, language.Language) {
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
	for _, l := range []struct{ pkg, name, src string }{
		{"pkg/lib", "app", "a.dart"},
		{"pkg/lib/src/model", "model", "model.dart"},
		{"pkg/lib/src/util", "util", "util.dart"},
	} {
		f := rule.EmptyFile(l.pkg+"/BUILD.bazel", l.pkg)
		r := rule.NewRule("dart_library", l.name)
		r.SetAttr("package_name", "app")
		r.SetAttr("srcs", []string{l.src})
		r.Insert(f)
		ix.AddRule(c, r, f)
	}
	ix.Finish()
	return c, ix, lang
}

// resolveSplit resolves, against splitIndex, a rule importing uris (a bare
// package name, or a file's `package:` URI).
func resolveSplit(t *testing.T, kind, pkg, name string, uris ...string) []string {
	t.Helper()
	c, ix, lang := splitIndex(t)
	r := rule.NewRule(kind, name)
	if kind == "dart_library" {
		r.SetAttr("package_name", "app")
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

func TestResolveSplitPackageByFile(t *testing.T) {
	for _, tt := range []struct {
		desc, kind, pkg, name string
		uris                  []string
		want                  []string
	}{
		{
			"lib/ library to its directories, never itself",
			"dart_library", "pkg/lib", "app",
			[]string{"package:app/a.dart", "package:app/src/model/model.dart", "package:app/src/util/util.dart"},
			[]string{"//pkg/lib/src/model", "//pkg/lib/src/util"},
		},
		{
			"directory library to a sibling, not the package's lib/ library",
			"dart_library", "pkg/lib/src/model", "model",
			[]string{"package:app/src/util/util.dart"},
			[]string{"//pkg/lib/src/util"},
		},
		{
			"an own-package file no rule holds is never a dep",
			"dart_library", "pkg/lib/src/model", "model",
			[]string{"package:app/src/model/model.g.dart"},
			nil,
		},
		{
			"test to the rule holding each imported file, pub by package",
			"dart_test", "pkg/test", "app_test",
			[]string{"package:app/a.dart", "package:app/src/model/model.dart", "package:path/path.dart"},
			[]string{"//pkg/lib/src/model", "//pkg/lib:app", "@pub_deps//:path"},
		},
		{
			"a file no rule holds falls back to the package",
			"dart_binary", "pkg/bin", "main",
			[]string{"package:app/missing.dart"},
			[]string{"//pkg/lib:app"},
		},
	} {
		got := resolveSplit(t, tt.kind, tt.pkg, tt.name, tt.uris...)
		if !slices.Equal(got, tt.want) {
			t.Errorf("%s: deps %v, want %v", tt.desc, got, tt.want)
		}
	}
}

func TestSplitLibraryIndexedByFileNotDirectoryName(t *testing.T) {
	c, _, _ := splitIndex(t)
	r := rule.NewRule("dart_library", "path")
	r.SetAttr("package_name", "app")
	r.SetAttr("srcs", []string{"path.dart"})
	var got []string
	for _, s := range (&dartLang{}).importSpecs(c, r, "pkg/lib/src/path") {
		got = append(got, s.Imp)
	}
	want := []string{"package:app/src/path/path.dart"}
	if !slices.Equal(got, want) {
		t.Errorf("specs %v, want %v", got, want)
	}
}
