package dart

import (
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

	pubDepsRepo := ""
	if c.Exts != nil {
		if repo, ok := c.Exts["dart_pub_deps_repo"].(string); ok {
			pubDepsRepo = repo
		}
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

		// External repository (pub package)
		var lbl label.Label
		if pubDepsRepo != "" {
			lbl = label.New(pubDepsRepo, "", pkg)
		} else {
			lbl = label.New(pkg, "", pkg)
		}
		deps = append(deps, lbl.String())
	}

	if len(deps) > 0 {
		sort.Strings(deps)
		r.SetAttr("deps", deps)
	}
}
