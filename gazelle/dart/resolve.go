package dart

import (
	"log"
	"sort"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Imports returns the import specifications for a rule.
// These are used to build the import index for dependency resolution.
func (d *dartLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	// A dart_library provides its package name as an import
	if r.Kind() == "dart_library" {
		name := r.Name()
		return []resolve.ImportSpec{
			{Lang: dartName, Imp: name},
		}
	}
	return nil
}

// Embeds returns rules that this rule embeds (not used for Dart).
func (d *dartLang) Embeds(r *rule.Rule, from label.Label) []label.Label {
	return nil
}

// Resolve resolves import dependencies for a rule.
func (d *dartLang) Resolve(c *config.Config, ix *resolve.RuleIndex, rc *repo.RemoteCache, r *rule.Rule, rawImports interface{}, from label.Label) {
	is, ok := rawImports.(*importSet)
	if !ok || is == nil {
		return
	}

	var deps []string
	for _, pkg := range is.SortedPackages() {
		// Skip self-references (importing own package)
		if pkg == r.Name() {
			continue
		}

		// Try to find in the rule index first (first-party deps)
		spec := resolve.ImportSpec{Lang: dartName, Imp: pkg}
		matches := ix.FindRulesByImportWithConfig(c, spec, dartName)
		if len(matches) > 0 {
			dep := matches[0].Label
			depLabel := dep.Rel(from.Repo, from.Pkg)
			deps = append(deps, depLabel.String())
			continue
		}

		// Try external repository (pub package)
		// Convention: @<package_name> or @pub_deps//<package_name>
		lbl := label.New(pkg, "", pkg)
		deps = append(deps, lbl.String())
		log.Printf("gazelle: dart: unresolved import %q for %s, assuming external @%s", pkg, from, pkg)
	}

	if len(deps) > 0 {
		sort.Strings(deps)
		r.SetAttr("deps", deps)
	}
}
