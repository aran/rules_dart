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

// libDirOf is the repo-relative lib/ directory of a package rooted at root.
func libDirOf(root string) string {
	if root == "" {
		return "lib"
	}
	return root + "/lib"
}

// packageNameIn is the Dart package a directory's sources belong to: for a
// directory under a package's lib/, the package named at its root;
// otherwise the directory's own (`libraryName`).
func packageNameIn(c *config.Config, rel string) string {
	p := placeDir(rel)
	if p.Split {
		return libraryName(p.Root, filepath.Join(c.RepoRoot, filepath.FromSlash(p.Root)), c)
	}
	return libraryName(rel, filepath.Join(c.RepoRoot, filepath.FromSlash(rel)), c)
}

// extKeyPackageDecl holds the nearest `dart_package_metadata` at or above
// the directory being configured.
const extKeyPackageDecl = "dart_package_decl"

// packageDecl is a hand-written `dart_package_metadata`: the directory that
// declares it and its target name.
type packageDecl struct {
	Rel, Name, PackageName string
}

// configurePackageDecl records a directory's `dart_package_metadata`, so a
// library in a directory under that package's lib/ can name it too.
func configurePackageDecl(c *config.Config, rel string, f *rule.File) {
	for _, r := range f.Rules {
		if r.Kind() == "dart_package_metadata" {
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts[extKeyPackageDecl] = &packageDecl{Rel: rel, Name: r.Name(), PackageName: r.AttrString("package_name")}
			return
		}
	}
}

// packageDeclFor returns the `dart_package_metadata` for the package a rule
// in args.Rel belongs to, as a label relative to args.Rel, and the package
// name it declares: the directory's own declaration, or, for a directory
// under a package's lib/, the declaration at the package's root.
func packageDeclFor(args language.GenerateArgs) (string, string) {
	if decl, name := packageDeclLabel(args); decl != "" {
		return decl, name
	}
	p := placeDir(args.Rel)
	d, ok := args.Config.Exts[extKeyPackageDecl].(*packageDecl)
	if !ok || d == nil || !p.Split || d.Rel != p.Root {
		return "", ""
	}
	return label.New("", d.Rel, d.Name).Rel("", args.Rel).String(), d.PackageName
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
