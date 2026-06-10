package dart

import (
	"sort"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// indexedKinds is the set of rule kinds that provide a Dart package for
// import resolution: the dart_library primitive plus every convenience
// macro (each wraps a dart_library under the hood).
var indexedKinds = func() map[string]bool {
	m := map[string]bool{"dart_library": true}
	for _, k := range macroKinds {
		m[k] = true
	}
	return m
}()

// Imports returns the import specifications for a rule.
// These are used to build the import index for dependency resolution.
func (d *dartLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	// A dart_library (or macro wrapping one) provides its rule name as an
	// import, plus its `package_name` attr when that differs — imports use
	// the Dart package name (`package:<package_name>/...`), which need not
	// match the Bazel target name.
	if !indexedKinds[r.Kind()] {
		return nil
	}
	specs := []resolve.ImportSpec{
		{Lang: dartName, Imp: r.Name()},
	}
	if pkgName := r.AttrString("package_name"); pkgName != "" && pkgName != r.Name() {
		specs = append(specs, resolve.ImportSpec{Lang: dartName, Imp: pkgName})
	}
	return specs
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

		// Check for gazelle:resolve override first
		spec := resolve.ImportSpec{Lang: dartName, Imp: pkg}
		if override, ok := resolve.FindRuleWithOverride(c, spec, dartName); ok {
			deps = append(deps, override.Rel(from.Repo, from.Pkg).String())
			continue
		}

		// Try to find in the rule index (first-party deps). Skip exact
		// self-matches (a rule whose package_name is indexed can match its
		// own import set) but keep legitimate intra-package cross-target
		// deps — those are filtered above only when pkg == r.Name().
		matches := ix.FindRulesByImportWithConfig(c, spec, dartName)
		matched := false
		for _, m := range matches {
			if m.IsSelfImport(from) {
				continue
			}
			deps = append(deps, m.Label.Rel(from.Repo, from.Pkg).String())
			matched = true
			break
		}
		if matched {
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
