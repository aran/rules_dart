package dart

import (
	"log"
	"os"
	"path"
	"path/filepath"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A package's facts are stated once, on the `dart_package_metadata` in the
// BUILD file at its root, the Bazel stand-in for its pubspec.yaml, and every
// rule Gazelle writes for the package names it with `package`: its library
// and codegen targets, and the binaries and tests in any directory of the
// package -- its root, bin/, test/, tool/, example/ -- (package_root.go).
//
// Gazelle writes the metadata from what states the package's facts: its name
// and language version from the `# gazelle:dart_package_name` and
// `# gazelle:dart_language_version` directives and the pubspec.yaml at the
// root (agreement.go), its hooks from hook/ (hook.go), and its license file,
// the root's `NOTICES`, or else `LICENSE`, as `pub.from_lock()` chooses. A
// package nothing states a fact of has none: the rules name it after its
// directory without one. At the repository's root, which gives no name, a
// target naming none is named after itself, so a package there with codegen
// targets has one stating its library's name.
//
// A package has one `dart_package_metadata`. Gazelle writes it named
// metadataName, and a `dart_package_metadata` already at the root is the
// package's, whatever its name, and is an error where the root's BUILD file
// holds two. Gazelle rewrites what it writes there and keeps the rest, such as
// `code_assets`, `data_assets`, `link_hook_assets` and `linked_code_assets`,
// which only a person states (what a link hook promises is in its code); a
// `# keep` attribute stays as it is, and is an error where it disagrees with a
// directive or the pubspec.

// metadataName is the name Gazelle gives a `dart_package_metadata` it
// writes: not a Dart package name, so never the name of the package's library.
const metadataName = "pubspec-metadata"

// packageMetadata is the `dart_package_metadata` of the package rooted at
// Root, named Name.
type packageMetadata struct {
	Root, Name string
}

// labelFrom is the metadata's label, relative to directory rel.
func (m *packageMetadata) labelFrom(rel string) string {
	return label.New("", m.Root, m.Name).Rel("", rel).String()
}

// metadataOf is the `dart_package_metadata` of the package rooted at root,
// or nil when it has none: the one already in its BUILD file, or the one
// Gazelle writes when the package has Dart files it writes rules for and a
// fact to state.
func (d *dartLang) metadataOf(c *config.Config, root string) *packageMetadata {
	if decl := packageDeclAt(c, root); decl != nil {
		return &packageMetadata{Root: root, Name: decl.Name}
	}
	scan := d.scan.scanOf(c, root)
	if !scan.hasRules() {
		return nil
	}
	// At the repository's root, a target naming none is named after itself,
	// so the codegen targets need the library's name stated.
	if !d.scan.statesFacts(c, root) && (root != "" || len(scan.annotated) == 0) {
		return nil
	}
	return &packageMetadata{Root: root, Name: metadataName}
}

// statesFacts reports whether anything states a fact of the package rooted
// at root: a pubspec.yaml, a directive, a hook, a license file.
func (s *scanState) statesFacts(c *config.Config, root string) bool {
	if hasPubspec(c, root) || s.licenseFile(root) != "" {
		return true
	}
	if directiveFact(c, keyPackageName) != nil || directiveFact(c, keyLanguageVersion) != nil {
		return true
	}
	for _, h := range hookKinds {
		if s.hookLabel(h, root) != "" {
			return true
		}
	}
	return false
}

// licenseFile is the license text of the package rooted at root: `NOTICES`
// if its root has one, else `LICENSE`, by exact name, as `flutter build`
// reads them; "" when it has neither.
func (s *scanState) licenseFile(root string) string {
	files := s.visibleFiles(root)
	for _, name := range []string{"NOTICES", "LICENSE"} {
		if hasFile(files, name) {
			return name
		}
	}
	return ""
}

// metadataRule is the `dart_package_metadata` Gazelle writes for the package
// rooted at root. A `code_assets` the package's library states, as earlier
// rules_dart versions had it, moves onto the metadata (`moveCodeAssets`).
func (d *dartLang) metadataRule(c *config.Config, root string, m *packageMetadata, f *rule.File) *rule.Rule {
	r := rule.NewRule("dart_package_metadata", m.Name)
	r.SetAttr("package_name", libraryName(root, c))
	if lv := languageVersionOf(c, root); lv != "" {
		r.SetAttr("language_version", lv)
	}
	for _, h := range hookKinds {
		if l := d.scan.hookLabel(h, root); l != "" {
			r.SetAttr(h.attr, l)
		}
	}
	if l := d.scan.licenseFile(root); l != "" {
		r.SetAttr("license_file", l)
	}
	// The package's rules name it from every directory below its root too.
	r.SetAttr("visibility", []string{label.New("", root, "__subpackages__").String()})
	moveCodeAssets(r, root, f)
	return r
}

// moveCodeAssets gives r, the package's metadata, the `code_assets` a
// library in f, the BUILD file at the package's root, states, which
// `dart_library` no longer takes. Gazelle's merge sets it only on a metadata
// stating none, and removes it from the library. Where the metadata states
// its own, the library's are logged as dropped.
func moveCodeAssets(r *rule.Rule, root string, f *rule.File) {
	if f == nil {
		return
	}
	var existing *rule.Rule
	for _, e := range f.Rules {
		if e.Kind() == "dart_package_metadata" && e.Name() == r.Name() {
			existing = e
		}
	}
	for _, lib := range f.Rules {
		if lib.Kind() != "dart_library" || lib.Attr("code_assets") == nil || lib.ShouldKeep() || kept(lib, "code_assets") {
			continue
		}
		if existing != nil && existing.Attr("code_assets") != nil {
			log.Printf("dart: %s: removing `code_assets` from %q, as `dart_library` "+
				"takes none; the package's `dart_package_metadata` %q states its own, "+
				"so add any of these it lacks there", path.Join(root, filepath.Base(f.Path)),
				lib.Name(), r.Name())
			continue
		}
		r.SetAttr("code_assets", lib.Attr("code_assets"))
	}
}

// setPackage names, on r, a rule Gazelle writes in directory rel for the
// package rooted at root, that package's metadata, when it has one.
func (d *dartLang) setPackage(r *rule.Rule, c *config.Config, root, rel string) {
	if m := d.metadataOf(c, root); m != nil {
		r.SetAttr("package", m.labelFrom(rel))
	}
}

// statedPackageName is the package name stated for directory rel: by a
// directive, else by the pubspec.yaml at the package's root, else, for a
// package with neither, by the `dart_package_metadata` already there; ""
// when none states one. `checkAgreement` has made sure the directive and
// the pubspec, and a `# keep` attribute, do not disagree.
func statedPackageName(c *config.Config, rel string) string {
	if f := directiveFact(c, keyPackageName); f != nil {
		return f.Value
	}
	root, err := packageRootOf(c, rel)
	if err != nil {
		return ""
	}
	if hasPubspec(c, root) {
		name, _ := pubspecFacts(c, root)
		return name
	}
	if decl := packageDeclAt(c, root); decl != nil {
		return decl.PackageName
	}
	return ""
}

// languageVersionOf is the language version of the package rooted at root,
// stated as its name is (`statedPackageName`), or "".
func languageVersionOf(c *config.Config, root string) string {
	if f := directiveFact(c, keyLanguageVersion); f != nil {
		return f.Value
	}
	if hasPubspec(c, root) {
		_, lv := pubspecFacts(c, root)
		return lv
	}
	if decl := packageDeclAt(c, root); decl != nil {
		return decl.LanguageVersion
	}
	return ""
}

// hasPubspec reports whether the package rooted at root has a pubspec.yaml.
func hasPubspec(c *config.Config, root string) bool {
	_, err := os.Stat(filepath.Join(c.RepoRoot, filepath.FromSlash(pubspecFile(root))))
	return err == nil
}
