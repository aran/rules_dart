package dart

import (
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules generates Dart BUILD rules for a directory.
func (d *dartLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	// Parse all Dart files in this directory
	dartFiles, err := ParseDartDir(args.Dir, args.RegularFiles)
	if err != nil || len(dartFiles) == 0 {
		return language.GenerateResult{}
	}

	// Classify files into categories based on directory conventions
	var libFiles, binFiles, testFiles []DartFileInfo
	for _, f := range dartFiles {
		switch {
		case isInDir(args.Rel, "test") || strings.HasSuffix(f.Path, "_test.dart"):
			testFiles = append(testFiles, f)
		case isInDir(args.Rel, "bin"):
			binFiles = append(binFiles, f)
		default:
			libFiles = append(libFiles, f)
		}
	}

	var gen []*rule.Rule
	var imports []interface{}

	// Generate dart_library for lib/ directories
	if len(libFiles) > 0 {
		r := rule.NewRule("dart_library", libraryName(args.Rel, args.Dir, args.Config))
		srcs := fileNames(libFiles)
		sort.Strings(srcs)
		r.SetAttr("srcs", srcs)
		r.SetAttr("visibility", []string{"//visibility:public"})
		needsPkgName := false
		if args.Config.Exts != nil {
			if _, ok := args.Config.Exts["dart_package_name"].(string); ok {
				needsPkgName = true
			}
		}
		if FindPubspecName(args.Dir, args.Rel) != "" {
			needsPkgName = true
		}
		if needsPkgName {
			r.SetAttr("package_name", r.Name())
		}
		gen = append(gen, r)
		imports = append(imports, collectImports(libFiles))
	}

	// Generate dart_binary for bin/ files
	for _, f := range binFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_binary", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	// Generate dart_test for test files
	for _, f := range testFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_test", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
	}
}

// libraryName determines the dart_library target name.
func libraryName(rel string, dir string, c *config.Config) string {
	if c.Exts != nil {
		if name, ok := c.Exts["dart_package_name"].(string); ok && name != "" {
			return name
		}
	}
	if name := FindPubspecName(dir, rel); name != "" {
		return name
	}
	if rel == "" {
		return "lib"
	}
	return path.Base(rel)
}

// isInDir checks if a relative path is within a conventional Dart directory.
func isInDir(rel string, dir string) bool {
	return rel == dir || strings.HasPrefix(rel, dir+"/")
}

// fileNames extracts file names from DartFileInfo slices.
func fileNames(files []DartFileInfo) []string {
	names := make([]string, len(files))
	for i, f := range files {
		names[i] = f.Path
	}
	return names
}

// importSet collects unique package: imports from a set of files.
type importSet struct {
	packages map[string]bool
}

func collectImports(files []DartFileInfo) *importSet {
	is := &importSet{packages: make(map[string]bool)}
	for _, f := range files {
		for _, imp := range f.Imports {
			if imp.IsPackage {
				is.packages[imp.Package] = true
			}
		}
	}
	return is
}

// SortedPackages returns sorted package names.
func (is *importSet) SortedPackages() []string {
	var pkgs []string
	for p := range is.packages {
		pkgs = append(pkgs, p)
	}
	sort.Strings(pkgs)
	return pkgs
}

// HasDartFiles checks if a directory contains Dart files.
func HasDartFiles(files []string) bool {
	for _, f := range files {
		if filepath.Ext(f) == ".dart" {
			return true
		}
	}
	return false
}
