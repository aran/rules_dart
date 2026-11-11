package dart

import (
	"testing"

	"github.com/bazelbuild/bazel-gazelle/rule"
)

// mergeMetadata merges gen into the `dart_package_metadata` of the BUILD
// file build, as Gazelle's merger does, and returns the result.
func mergeMetadata(t *testing.T, build string, gen *rule.Rule) *rule.Rule {
	t.Helper()
	f, err := rule.LoadData("BUILD.bazel", "", []byte(build))
	if err != nil {
		t.Fatal(err)
	}
	dst := f.Rules[0]
	rule.MergeRules(gen, dst, dartKinds(defaultBuilders())["dart_package_metadata"].MergeableAttrs, "BUILD.bazel")
	return dst
}

func TestMetadataMerge(t *testing.T) {
	const build = `
dart_package_metadata(
    name = "metadata",
    package_name = "old",
    code_assets = [":native"],
    data_assets = [":data"],
    language_version = "3.10",
    license_file = "LICENSE",
    link_hook = "//hook:link",
    link_hook_assets = ["package:old/index.json"],
    linked_code_assets = [":linked"],
    version = "1.2.3",
)
`
	gen := rule.NewRule("dart_package_metadata", "metadata")
	gen.SetAttr("package_name", "new")
	gen.SetAttr("language_version", "3.12")
	gen.SetAttr("build_hook", "//hook:build")
	got := mergeMetadata(t, build, gen)
	for attr, want := range map[string]string{
		// What Gazelle writes, it rewrites, and removes once gone.
		"package_name":     "new",
		"language_version": "3.12",
		"build_hook":       "//hook:build",
		"link_hook":        "",
		"license_file":     "",
		// What only a person states, it keeps.
		"version": "1.2.3",
	} {
		if v := got.AttrString(attr); v != want {
			t.Errorf("%s = %q, want %q", attr, v, want)
		}
	}
	if assets := got.AttrStrings("code_assets"); len(assets) != 1 || assets[0] != ":native" {
		t.Errorf("code_assets = %v, want [:native]", assets)
	}
	if assets := got.AttrStrings("data_assets"); len(assets) != 1 || assets[0] != ":data" {
		t.Errorf("data_assets = %v, want [:data]", assets)
	}
	if assets := got.AttrStrings("link_hook_assets"); len(assets) != 1 || assets[0] != "package:old/index.json" {
		t.Errorf("link_hook_assets = %v, want [package:old/index.json]", assets)
	}
	if assets := got.AttrStrings("linked_code_assets"); len(assets) != 1 || assets[0] != ":linked" {
		t.Errorf("linked_code_assets = %v, want [:linked]", assets)
	}
}

func TestMetadataMergeKeep(t *testing.T) {
	const build = `
dart_package_metadata(
    name = "metadata",
    package_name = "pinned",  # keep
    language_version = "3.10",  # keep
)
`
	gen := rule.NewRule("dart_package_metadata", "metadata")
	gen.SetAttr("package_name", "new")
	gen.SetAttr("language_version", "3.12")
	got := mergeMetadata(t, build, gen)
	if got.AttrString("package_name") != "pinned" || got.AttrString("language_version") != "3.10" {
		t.Errorf("a `# keep` attribute was rewritten: %q, %q", got.AttrString("package_name"), got.AttrString("language_version"))
	}
}

func TestRemovedFactAttrsManaged(t *testing.T) {
	// Every kind Gazelle writes for a package removes the inline facts an
	// old BUILD file states on it.
	for _, kind := range append([]string{"dart_library", "dart_binary", "dart_test", "dart_codegen", "dart_aggregate_codegen", "dart_sqlcodegen"}, macroKinds(defaultBuilders())...) {
		for _, a := range append([]string{"package"}, removedFactAttrs...) {
			if !dartKinds(defaultBuilders())[kind].MergeableAttrs[a] {
				t.Errorf("%s does not manage %s", kind, a)
			}
		}
	}
	if !dartKinds(defaultBuilders())["dart_library"].MergeableAttrs["code_assets"] {
		t.Error("dart_library does not manage code_assets")
	}
	if dartKinds(defaultBuilders())["dart_package_metadata"].MergeableAttrs["code_assets"] {
		t.Error("dart_package_metadata manages code_assets, which only a person states")
	}
	for _, a := range []string{"data_assets", "link_hook_assets", "linked_code_assets"} {
		if dartKinds(defaultBuilders())["dart_package_metadata"].MergeableAttrs[a] {
			t.Errorf("dart_package_metadata manages %s, which only a person states", a)
		}
	}
}
