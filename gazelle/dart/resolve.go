package dart

import (
	"log"
	"path"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// indexedKinds is the set of rule kinds that provide a Dart package for
// import resolution. A codegen macro is not one: the library holding its
// sources lists what it generates.
var indexedKinds = map[string]bool{"dart_library": true, "dart_package_cycle": true}

// Imports returns the import specifications for a rule.
// These are used to build the import index for dependency resolution.
func (d *dartLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	return d.importSpecs(c, r, f.Pkg)
}

// importSpecs is what a rule in Bazel package rel provides: the `package:`
// URI of each of its sources, and the package itself, by its rule name and
// its package's name.
func (d *dartLang) importSpecs(c *config.Config, r *rule.Rule, rel string) []resolve.ImportSpec {
	if !indexedKinds[r.Kind()] {
		return nil
	}
	if r.Kind() == "dart_package_cycle" {
		// What its members, written below it, provide (cycle.go).
		if decl := declAt(c, rel, r.Name()); decl != nil {
			return append([]resolve.ImportSpec{{Lang: dartName, Imp: r.Name()}}, d.cycles.cycleSpecs(decl)...)
		}
		return nil
	}
	place := placeOf(c, rel)
	pkgName := libraryPackageName(c, r, place)
	specs := []resolve.ImportSpec{{Lang: dartName, Imp: r.Name()}}
	if pkgName != r.Name() {
		specs = append(specs, resolve.ImportSpec{Lang: dartName, Imp: pkgName})
	}
	if place.Err != nil {
		return specs
	}
	for _, src := range r.AttrStrings("srcs") {
		if src == "" || strings.ContainsAny(src[:1], "@:/") {
			continue
		}
		if uri := packageURI(pkgName, place.Root, path.Join(rel, src)); uri != "" {
			specs = append(specs, resolve.ImportSpec{Lang: dartName, Imp: uri})
		}
	}
	return specs
}

// libraryPackageName is the Dart package of r, a library at place: the one
// its `package` declares, which Gazelle writes from the facts stated for its
// root, or else the name of its root's directory, or, at the repository's
// root, its own name, as `dart_library` names it.
func libraryPackageName(c *config.Config, r *rule.Rule, place packagePlace) string {
	if place.Err == nil && r.AttrString("package") != "" {
		if name := statedPackageName(c, place.Root); name != "" {
			return name
		}
		return libraryName(place.Root, c)
	}
	if place.Err == nil && place.Root != "" {
		return path.Base(place.Root)
	}
	return r.Name()
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
	if is.cycle != nil {
		// A generator in a cycle reads every member's sources, not the
		// cycle's library, which holds what it generates; and what the
		// members import from outside the cycle (cycle.go).
		is = d.cycleCodegenImports(is, from)
	}

	pubDepsRepo := ""
	if c.Exts != nil {
		if repo, ok := c.Exts["dart_pub_deps_repo"].(string); ok {
			pubDepsRepo = repo
		}
	}

	// A rule doesn't depend on a package it provides itself; it depends only
	// on the other rules holding the files it imports from it. Only a
	// library provides one: a binary or test named like a package (the
	// `bin/<package>.dart` that `dart create` writes) still depends on it.
	provided := map[string]bool{}
	for _, spec := range d.importSpecs(c, r, from.Pkg) {
		provided[spec.Imp] = true
	}

	var deps []string
	for _, pkg := range is.SortedPackages() {
		uris := is.SortedURIs(pkg)
		if provided[pkg] {
			resolveFiles(c, ix, uris, from, &deps)
			continue
		}

		// Check for gazelle:resolve override first
		spec := resolve.ImportSpec{Lang: dartName, Imp: pkg}
		if override, ok := resolve.FindRuleWithOverride(c, spec, dartName); ok {
			deps = append(deps, override.Rel(from.Repo, from.Pkg).String())
			continue
		}

		// Each imported file resolves to the rule that holds it. The
		// package's name decides only when some file is in no indexed rule
		// (a pub package, or sources listed by glob).
		if len(uris) > 0 && resolveFiles(c, ix, uris, from, &deps) {
			continue
		}

		// Try to find in the rule index (first-party deps). Skip exact
		// self-matches (a rule whose package_name is indexed can match its
		// own import set) but keep legitimate intra-package cross-target
		// deps — those are filtered above only for a package this rule provides.
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

	deps = append(deps, is.labels...)
	if is.annotationPackage != "" {
		// The macro's annotation_dep is its builder's runtime package,
		// resolved as an import of it would be; the macro's own default
		// needs no statement.
		if lbl := pubPackageLabel(c, ix, is.annotationPackage, from, pubDepsRepo); lbl != is.annotationDefault {
			r.SetAttr("annotation_dep", lbl)
		} else {
			r.DelAttr("annotation_dep")
		}
	}
	if len(deps) > 0 {
		r.SetAttr("deps", dedupe(deps))
	}
}

// resolveFiles adds a dep on the rule holding each file URI, and reports
// whether every file was found in some rule (the importing rule included).
// A file held by more than one rule is logged and left out, not guessed;
// a `# gazelle:resolve dart <uri> <label>` directive picks one.
// pubPackageLabel is the label an import of package pkg, and no file of it,
// resolves to from a rule at from: an override, the rule that indexes it, or
// the package's pub repository.
func pubPackageLabel(c *config.Config, ix *resolve.RuleIndex, pkg string, from label.Label, pubDepsRepo string) string {
	spec := resolve.ImportSpec{Lang: dartName, Imp: pkg}
	if override, ok := resolve.FindRuleWithOverride(c, spec, dartName); ok {
		return override.Rel(from.Repo, from.Pkg).String()
	}
	for _, m := range ix.FindRulesByImportWithConfig(c, spec, dartName) {
		if !m.IsSelfImport(from) {
			return m.Label.Rel(from.Repo, from.Pkg).String()
		}
	}
	if pubDepsRepo != "" {
		return label.New(pubDepsRepo, "", pkg).String()
	}
	return label.New(pkg, "", pkg).String()
}

func resolveFiles(c *config.Config, ix *resolve.RuleIndex, uris []string, from label.Label, deps *[]string) bool {
	all := true
	for _, uri := range uris {
		spec := resolve.ImportSpec{Lang: dartName, Imp: uri}
		if override, ok := resolve.FindRuleWithOverride(c, spec, dartName); ok {
			*deps = append(*deps, override.Rel(from.Repo, from.Pkg).String())
			continue
		}
		var others []resolve.FindResult
		self := false
		for _, m := range ix.FindRulesByImportWithConfig(c, spec, dartName) {
			if m.IsSelfImport(from) {
				self = true
			} else {
				others = append(others, m)
			}
		}
		switch {
		case self:
		case len(others) == 1:
			*deps = append(*deps, others[0].Label.Rel(from.Repo, from.Pkg).String())
		case len(others) > 1:
			var labels []string
			for _, m := range others {
				labels = append(labels, m.Label.String())
			}
			log.Printf("dart: %s: %s is in more than one rule (%s); add a "+
				"`# gazelle:resolve dart %s <label>` directive to choose",
				from, uri, strings.Join(labels, ", "), uri)
		default:
			all = false
		}
	}
	return all
}

func dedupe(deps []string) []string {
	sort.Strings(deps)
	out := deps[:0]
	for i, d := range deps {
		if i == 0 || d != deps[i-1] {
			out = append(out, d)
		}
	}
	return out
}
