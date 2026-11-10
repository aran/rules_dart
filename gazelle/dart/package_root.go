package dart

import (
	"fmt"
	"path"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// placement is where a directory sits in its Dart package, by the rule
// `dart_library` applies (`package_root` in dart_library.bzl): a directory
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
// outside those is the hook/ directory of the package above it. No
// pubspec.yaml is read, so a package without one has the same layout as a
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

// packageRootOf is the root of the Dart package a directory belongs to: the
// root above its bin/, test/ or hook/ (`layoutOf`), or else above its lib/
// (`placeDir`), or else the directory itself.
func packageRootOf(rel string) (string, error) {
	if dir, root := layoutOf(rel); dir != "" {
		return root, nil
	}
	p := placeDir(rel)
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
	if root, err := packageRootOf(rel); err == nil {
		return libraryName(root, c)
	}
	return libraryName(rel, c)
}

// extKeyPackageDecl holds the nearest `dart_package_metadata` at or above
// the directory being configured.
const extKeyPackageDecl = "dart_package_decl"

// packageDecl is a hand-written `dart_package_metadata`: the directory that
// declares it and its target name.
type packageDecl struct {
	Rel, Name, PackageName, LanguageVersion string
}

// label is the declaration's label, from the repository root.
func (d *packageDecl) label() string {
	return label.New("", d.Rel, d.Name).String()
}

// configurePackageDecl records a directory's `dart_package_metadata`, so a
// library in a directory under that package's lib/ can name it too.
func configurePackageDecl(c *config.Config, rel string, f *rule.File) {
	for _, r := range f.Rules {
		if r.Kind() == "dart_package_metadata" {
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts[extKeyPackageDecl] = &packageDecl{
				Rel:             rel,
				Name:            r.Name(),
				PackageName:     r.AttrString("package_name"),
				LanguageVersion: r.AttrString("language_version"),
			}
			return
		}
	}
}

// packageDeclOf is the `dart_package_metadata` the package a rule in
// args.Rel belongs to is declared by (`packageDeclIn`).
func packageDeclOf(args language.GenerateArgs) *packageDecl {
	return packageDeclIn(args.Config, args.Rel)
}

// packageDeclIn is the `dart_package_metadata` the package of the library
// directory rel is declared by: the directory's own declaration, or, for the
// package's lib/ or a directory under it, the declaration at the package's
// root. nil when there is none.
func packageDeclIn(c *config.Config, rel string) *packageDecl {
	d, ok := c.Exts[extKeyPackageDecl].(*packageDecl)
	if !ok || d == nil {
		return nil
	}
	if d.Rel == rel {
		return d
	}
	if p := placeDir(rel); p.Err == nil && p.Root == d.Rel {
		return d
	}
	return nil
}

// packageDeclFor returns the label, relative to args.Rel, of the
// `dart_package_metadata` a rule in args.Rel names (`packageDeclOf`), or ""
// when there is none.
//
// A package that has adopted a declaration must not have the inline attributes
// written back onto its rules: the two spellings are mutually exclusive and a
// rule carrying both fails at analysis, so re-running Gazelle over a converted
// package would break exactly the packages that adopted the tidier form.
// Detecting the declaration rather than emitting one is what makes adoption
// incremental -- Gazelle keeps writing the inline attributes everywhere else,
// where they are machine-maintained from one derived value and cannot drift.
func packageDeclFor(args language.GenerateArgs) string {
	d := packageDeclOf(args)
	if d == nil {
		return ""
	}
	return label.New("", d.Rel, d.Name).Rel("", args.Rel).String()
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
