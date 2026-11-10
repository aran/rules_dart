package dart

import (
	"fmt"
	"path"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// placement is where a directory sits in its Dart package, by the rule
// `dart_library` applies (`locate_package_root` in dart_library.bzl): a directory
// with no `lib` component is a package root; a directory inside a `lib/` --
// `lib/` itself or one under it -- belongs to the package rooted above that
// `lib`. A directory with two `lib` components is ambiguous.
type placement struct {
	Root  string // the package root, repo-relative; "" for the repository root
	Split bool   // the directory is under the package's lib/, not lib/ itself
	Err   error  // set when the directory's package root is ambiguous
}

func placeDir(rel string) placement {
	if rel == "" {
		return placement{}
	}
	parts := strings.Split(rel, "/")
	var libAt []int
	for i, p := range parts {
		if p == "lib" {
			libAt = append(libAt, i)
		}
	}
	switch len(libAt) {
	case 0:
		return placement{Root: rel}
	case 1:
		return placement{
			Root:  strings.Join(parts[:libAt[0]], "/"),
			Split: libAt[0] != len(parts)-1,
		}
	}
	return placement{Err: fmt.Errorf(
		"%s has a directory named `lib` inside another `lib/`, so its Dart "+
			"package root is ambiguous and dart_library rejects it; rename "+
			"the inner `lib` directory", rel)}
}

// layoutOf is the pub layout directory a directory is in -- "bin" or
// "test", for a package's bin/ or test/ directory or one under it, or
// "hook", for a package's hook/ directory -- and the root of that package;
// "" when it is none of these.
//
// A directory inside a `lib/` is a library directory whatever else its path
// names. Elsewhere the nearest `bin` or `test` component decides, and the
// package root is the directory above it, as the package root of a
// directory inside a `lib/` is the directory above the `lib`: `pkg/bin` and
// `pkg/test/unit` belong to the package at `pkg`. A directory named `hook`
// outside those is the hook/ directory of the package above it. It places
// a directory that no pubspec.yaml or `dart_package_metadata` at or above
// it roots (`placeOf`), so that a package without one has the layout of a
// package with one.
func layoutOf(rel string) (dir, root string) {
	if rel == "" {
		return "", ""
	}
	parts := strings.Split(rel, "/")
	for _, p := range parts {
		if p == "lib" {
			return "", ""
		}
	}
	for i := len(parts) - 1; i >= 0; i-- {
		if parts[i] == "bin" || parts[i] == "test" {
			return parts[i], strings.Join(parts[:i], "/")
		}
	}
	if last := len(parts) - 1; parts[last] == "hook" {
		return "hook", strings.Join(parts[:last], "/")
	}
	return "", ""
}

// A Dart file belongs to the innermost package whose root holds it, and a
// package's root is the directory holding its pubspec.yaml, as pub writes
// the package's `rootUri` into package_config.json: every directory below
// the root, lib/, bin/, test/, tool/, example/ or any other, is in that
// package, up to the root of another package inside it. A
// `dart_package_metadata`, the Bazel stand-in for a pubspec.yaml, marks a
// package root just as one does. A directory with neither at or above it is
// placed by the layout `dart_library` applies to a package with no pubspec
// (`layoutOf`, `placeDir`).

// packagePlace is where a directory sits in its Dart package: the package's
// root, and the pub layout directory it is in -- "lib", "bin" or "test",
// for the package's lib/, bin/ or test/ or a directory under one, "hook"
// for its hook/ directory, or "" for its root or any other directory
// (tool/, example/).
type packagePlace struct {
	Root   string // repo-relative; "" for the repository root
	Layout string
	Err    error // set when the directory's package root is ambiguous
}

// placeOf is where directory rel, configured by c, sits in its package.
func placeOf(c *config.Config, rel string) packagePlace {
	if root, ok := declaredRootOf(c, rel); ok {
		if p := placeDir(root); p.Err != nil || p.Root != root {
			return packagePlace{Err: fmt.Errorf(
				"%s states a Dart package rooted inside a `lib/`, which "+
					"dart_library rejects; move the package out of the `lib/`", root)}
		}
		return packagePlace{Root: root, Layout: layoutUnder(root, rel)}
	}
	if dir, root := layoutOf(rel); dir != "" {
		return packagePlace{Root: root, Layout: dir}
	}
	p := placeDir(rel)
	if p.Err != nil {
		return packagePlace{Err: p.Err}
	}
	place := packagePlace{Root: p.Root}
	if rel != p.Root {
		place.Layout = "lib"
	}
	return place
}

// declaredRootOf is the root of the innermost package that a pubspec.yaml
// or a `dart_package_metadata` at or above directory rel states, if one
// does. The metadata is the one Configure recorded for rel
// (`configurePackageDecl`).
func declaredRootOf(c *config.Config, rel string) (string, bool) {
	decl, _ := c.Exts[extKeyPackageDecl].(*packageDecl)
	if decl != nil && !within(rel, decl.Rel) {
		decl = nil
	}
	for dir := rel; ; dir = parentDir(dir) {
		if decl != nil && dir == decl.Rel {
			return dir, true
		}
		if hasPubspec(c, dir) {
			return dir, true
		}
		if dir == "" {
			return "", false
		}
	}
}

// layoutUnder is the pub layout directory (`packagePlace.Layout`) that
// directory rel is in, in the package rooted at root: the first directory
// below the root decides.
func layoutUnder(root, rel string) string {
	if rel == root {
		return ""
	}
	sub := relTo(root, rel)
	switch first, _, _ := strings.Cut(sub, "/"); first {
	case "lib", "bin", "test":
		return first
	case "hook":
		if sub == "hook" {
			return "hook"
		}
	}
	return ""
}

// within reports whether directory rel is dir or below it.
func within(rel, dir string) bool {
	return dir == "" || rel == dir || strings.HasPrefix(rel, dir+"/")
}

// parentDir is the directory above rel; "" above a top-level directory.
func parentDir(rel string) string {
	if i := strings.LastIndex(rel, "/"); i >= 0 {
		return rel[:i]
	}
	return ""
}

// packageRootOf is the root of the Dart package directory rel belongs to
// (`placeOf`).
func packageRootOf(c *config.Config, rel string) (string, error) {
	p := placeOf(c, rel)
	return p.Root, p.Err
}

// pubspecFile is the repo-relative path of the pubspec.yaml a package rooted
// at root would have. Only that one states the package's facts: a pubspec
// above the root is another package's.
func pubspecFile(root string) string {
	return path.Join(root, "pubspec.yaml")
}

// pubspecFacts is the package name and language version the pubspec.yaml at
// a package's root states, each "" when it states none or there is none.
func pubspecFacts(c *config.Config, root string) (name, languageVersion string) {
	dir := filepath.Join(c.RepoRoot, filepath.FromSlash(root))
	return ParsePubspecName(dir), ParsePubspecLanguageVersion(dir)
}

// libDirOf is the repo-relative lib/ directory of a package rooted at root.
func libDirOf(root string) string {
	if root == "" {
		return "lib"
	}
	return root + "/lib"
}

// packageNameIn is the Dart package a directory's sources belong to: the
// name of the package rooted at `packageRootOf` (`libraryName`).
func packageNameIn(c *config.Config, rel string) string {
	if root, err := packageRootOf(c, rel); err == nil {
		return libraryName(root, c)
	}
	return libraryName(rel, c)
}

// extKeyPackageDecl holds the nearest `dart_package_metadata` at or above
// the directory being configured.
const extKeyPackageDecl = "dart_package_decl"

// packageDecl is a `dart_package_metadata` already in a BUILD file: the
// directory that declares it, its target name and the facts it states, and
// whether each of those is marked `# keep`, so that Gazelle leaves it as it
// is. Others names any further `dart_package_metadata` in the same file.
type packageDecl struct {
	Rel, Name, PackageName, LanguageVersion string
	KeepName, KeepVersion                   bool
	Others                                  []string
}

// label is the declaration's label, from the repository root.
func (d *packageDecl) label() string {
	return label.New("", d.Rel, d.Name).String()
}

// configurePackageDecl records a directory's `dart_package_metadata`, so
// the directories of its package below it find it too.
func configurePackageDecl(c *config.Config, rel string, f *rule.File) {
	if f == nil {
		return
	}
	var decl *packageDecl
	for _, r := range f.Rules {
		if r.Kind() != "dart_package_metadata" {
			continue
		}
		if decl != nil {
			decl.Others = append(decl.Others, r.Name())
			continue
		}
		decl = &packageDecl{
			Rel:             rel,
			Name:            r.Name(),
			PackageName:     r.AttrString("package_name"),
			LanguageVersion: r.AttrString("language_version"),
			KeepName:        r.ShouldKeep() || kept(r, "package_name"),
			KeepVersion:     r.ShouldKeep() || kept(r, "language_version"),
		}
	}
	if decl == nil {
		return
	}
	if c.Exts == nil {
		c.Exts = make(map[string]interface{})
	}
	c.Exts[extKeyPackageDecl] = decl
}

// packageDeclAt is the `dart_package_metadata` already in the BUILD file at
// the package root root, or nil.
func packageDeclAt(c *config.Config, root string) *packageDecl {
	if d, ok := c.Exts[extKeyPackageDecl].(*packageDecl); ok && d != nil && d.Rel == root {
		return d
	}
	return nil
}

// packageURI is the `package:` URI of the repo-relative file in a package
// named pkg rooted at root, or "" when the file is outside the package's lib/.
func packageURI(pkg, root, file string) string {
	lib := libDirOf(root) + "/"
	if pkg == "" || !strings.HasPrefix(file, lib) {
		return ""
	}
	return "package:" + pkg + "/" + strings.TrimPrefix(file, lib)
}

// importedURI is the `package:` URI of the file an import names, when it
// names one: a `package:` import as written, or a relative import from the
// repo-relative file resolved inside its package's lib/. "" otherwise.
func importedURI(pkg, root, file string, imp DartImport) string {
	switch {
	case imp.IsPackage && imp.Path != "":
		return imp.URI
	case imp.IsRelative && !strings.Contains(imp.URI, ":"):
		return packageURI(pkg, root, path.Clean(path.Join(path.Dir(file), imp.URI)))
	}
	return ""
}
