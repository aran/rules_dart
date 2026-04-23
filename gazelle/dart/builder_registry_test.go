package dart

import (
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// TestMacroKindsBackedByDefaultBuilders enforces that every entry in
// `macroKinds` corresponds to a `defaultBuilders()` entry whose `Macro`
// field references it. Drift here means Gazelle either declares load
// symbols nothing emits, or registers builders whose macros aren't
// recognised as Dart rule kinds — both are silent footguns.
func TestMacroKindsBackedByDefaultBuilders(t *testing.T) {
	defaultsByMacroKind := map[string]bool{}
	for _, b := range defaultBuilders() {
		parts := splitOnPercent(b.Macro)
		if len(parts) != 2 {
			t.Fatalf("default builder %s has malformed Macro %q", b.Annotation, b.Macro)
		}
		defaultsByMacroKind[parts[1]] = true
	}
	for _, kind := range macroKinds {
		if !defaultsByMacroKind[kind] {
			t.Errorf("macroKinds entry %q has no backing builderInfo in defaultBuilders()", kind)
		}
	}
	for symbol := range defaultsByMacroKind {
		found := false
		for _, k := range macroKinds {
			if k == symbol {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("defaultBuilders() emits macro %q but it's not registered in macroKinds", symbol)
		}
	}
}

// TestMacroLoadInfosBackedByMacroKinds enforces that every symbol in
// `macroLoadInfos()` corresponds to an entry in `macroKinds`. Without
// this test, adding a new default builder and forgetting to extend
// `macroLoadInfos()` would silently break load-statement generation.
func TestMacroLoadInfosBackedByMacroKinds(t *testing.T) {
	lang := &dartLang{}
	_ = lang
	loadSymbols := map[string]bool{}
	for _, li := range macroLoadInfos() {
		for _, s := range li.Symbols {
			loadSymbols[s] = true
		}
	}
	for _, kind := range macroKinds {
		if !loadSymbols[kind] {
			t.Errorf("macroKinds entry %q has no matching symbol in macroLoadInfos()", kind)
		}
	}
	for symbol := range loadSymbols {
		found := false
		for _, k := range macroKinds {
			if k == symbol {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("macroLoadInfos() declares symbol %q but it's not registered in macroKinds", symbol)
		}
	}
}

// TestBuilderRegistryDeepClonesBetweenConfigs verifies that mutating a
// per-directory registry (via `dart_builder_config` / `dart_builder_runtime_dep`)
// doesn't bleed into sibling directories. Gazelle shallow-copies `c.Exts`
// on directory entry; the registry must clone on first access per config.
func TestBuilderRegistryDeepClonesBetweenConfigs(t *testing.T) {
	parent := &config.Config{Exts: map[string]interface{}{}}
	parentReg := builderRegistryOf(parent)
	for _, info := range parentReg.byAnnotation["JsonSerializable"] {
		info.Config = "{}" // canonical starting value
	}

	// Child shares `c.Exts` map by value after a shallow copy (Gazelle's
	// behaviour); registry pointer is shared until builderRegistryOf
	// deep-clones on first access in the child scope.
	child := &config.Config{Exts: map[string]interface{}{}}
	for k, v := range parent.Exts {
		child.Exts[k] = v
	}
	childReg := builderRegistryOf(child)
	for _, info := range childReg.byAnnotation["JsonSerializable"] {
		info.Config = `{"child": true}`
	}

	for _, info := range parentReg.byAnnotation["JsonSerializable"] {
		if info.Config != "{}" {
			t.Errorf("parent registry polluted by child mutation: %q",
				info.Config)
		}
	}
	for _, info := range childReg.byAnnotation["JsonSerializable"] {
		if info.Config != `{"child": true}` {
			t.Errorf("child mutation lost: %q", info.Config)
		}
	}
}

// TestDartBuilderDirectiveIgnored guards the D5 decision: the
// registration-adding `# gazelle:dart_builder` directive was ripped.
// Declaring it must not register a new builder.
func TestDartBuilderDirectiveIgnored(t *testing.T) {
	c := &config.Config{Exts: map[string]interface{}{}}
	f := &rule.File{
		Directives: []rule.Directive{
			{Key: "dart_builder", Value: "CustomAnnotation @x:shim macro=@x:defs.bzl%custom_library produces=.custom.dart"},
		},
	}
	configureBuilderDirectives(c, f)
	r := builderRegistryOf(c)
	if r.lookup("CustomAnnotation") != nil {
		t.Errorf("expected #gazelle:dart_builder to be ignored; got registration")
	}
}

// TestDartBuilderConfigDirectiveAppliesToAllFanOuts verifies that a
// per-annotation config directive reaches every builderInfo watching
// the annotation (e.g. @StackedApp's five sub-builders).
func TestDartBuilderConfigDirectiveAppliesToAllFanOuts(t *testing.T) {
	c := &config.Config{Exts: map[string]interface{}{}}
	f := &rule.File{
		Directives: []rule.Directive{
			{Key: "dart_builder_config", Value: `StackedApp {"navigator2": true}`},
		},
	}
	configureBuilderDirectives(c, f)
	r := builderRegistryOf(c)
	infos := r.byAnnotation["StackedApp"]
	if len(infos) == 0 {
		t.Fatal("expected @StackedApp to have registered sub-builders")
	}
	for _, info := range infos {
		if info.Config != `{"navigator2": true}` {
			t.Errorf("sub-builder %q missing config override", info.ShimLabel)
		}
	}
}

// TestMalformedBuilderDirectivesAreIgnored guards the warning path in
// configureBuilderDirectives: a one-word directive value (missing the
// required `<Annotation> <payload>` split) must not panic and must not
// mutate the registry. The warning itself goes via log.Printf — per
// upstream Gazelle convention it's fire-and-forget, so we only verify
// the observable effect on the registry.
func TestMalformedBuilderDirectivesAreIgnored(t *testing.T) {
	c := &config.Config{Exts: map[string]interface{}{}}
	// Snapshot the JsonSerializable entry's starting values so we can
	// confirm neither malformed directive clobbered them.
	r := builderRegistryOf(c)
	origRuntimeDep := ""
	origConfig := ""
	for _, info := range r.byAnnotation["JsonSerializable"] {
		origRuntimeDep = info.RuntimeDep
		origConfig = info.Config
		break
	}

	f := &rule.File{
		Directives: []rule.Directive{
			{Key: "dart_builder_runtime_dep", Value: "OnlyOneWord"},
			{Key: "dart_builder_config", Value: "JustOneWord"},
		},
	}
	configureBuilderDirectives(c, f)

	for _, info := range r.byAnnotation["JsonSerializable"] {
		if info.RuntimeDep != origRuntimeDep {
			t.Errorf("malformed runtime_dep directive mutated RuntimeDep: got %q, want %q",
				info.RuntimeDep, origRuntimeDep)
		}
		if info.Config != origConfig {
			t.Errorf("malformed config directive mutated Config: got %q, want %q",
				info.Config, origConfig)
		}
	}
}

// TestDartBuilderRuntimeDepAppliesToAllFanOuts verifies runtime-dep
// overrides reach every fan-out target.
func TestDartBuilderRuntimeDepAppliesToAllFanOuts(t *testing.T) {
	c := &config.Config{Exts: map[string]interface{}{}}
	f := &rule.File{
		Directives: []rule.Directive{
			{Key: "dart_builder_runtime_dep", Value: "StackedApp @my_fork//:stacked"},
		},
	}
	configureBuilderDirectives(c, f)
	r := builderRegistryOf(c)
	for _, info := range r.byAnnotation["StackedApp"] {
		if info.RuntimeDep != "@my_fork//:stacked" {
			t.Errorf("sub-builder %q runtime_dep override failed (got %q)",
				info.ShimLabel, info.RuntimeDep)
		}
	}
}

func splitOnPercent(s string) []string {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' {
			return []string{s[:i], s[i+1:]}
		}
	}
	return []string{s}
}
