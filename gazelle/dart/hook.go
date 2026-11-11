package dart

import (
	"log"
	"path"
	"path/filepath"

	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A package's hooks live in its hook/ directory, and Gazelle states each on
// the package's `dart_package_metadata`, at its root (metadata.go).
//
// hook/build.dart builds native code and data assets when pub gets the
// package. rules_dart never runs it, and fails every binary and test that
// reaches the package unless the metadata's `code_assets` and `data_assets`
// replace what it builds. So Gazelle states it, and the build says what to do.
//
// hook/link.dart decides what the package ships from a program's recorded
// uses; a linked `dart_program_assets` runs it from the metadata's
// `link_hook`, and its
// imports are the dependencies of the package's library, as pub requires.
//
// A package has Gazelle not see a hook with `# gazelle:exclude
// hook/build.dart` (or `hook/link.dart`).

// hookKind is one of a package's hooks: its file in hook/, the filegroup
// Gazelle holds it in there, and the `dart_package_metadata` attribute
// naming it.
type hookKind struct {
	file, target, attr string
}

var (
	buildHook = hookKind{file: "build.dart", target: "build", attr: "build_hook"}
	linkHook  = hookKind{file: "link.dart", target: "link", attr: "link_hook"}
	hookKinds = []hookKind{buildHook, linkHook}
)

// visibleFiles is the regular files of directory rel that Gazelle sees:
// those no `# gazelle:exclude` excludes. Nil when the directory is absent.
func (s *scanState) visibleFiles(rel string) []string {
	list := s.list
	if list == nil {
		list = gazelleDir
	}
	_, files, err := list(rel)
	if err != nil {
		return nil
	}
	return files
}

func hasFile(files []string, name string) bool {
	for _, f := range files {
		if f == name {
			return true
		}
	}
	return false
}

// hookLabel is the label, relative to the package's root, of the hook of
// the package rooted at root, or "" when it has none Gazelle sees.
func (s *scanState) hookLabel(h hookKind, root string) string {
	dir := path.Join(root, "hook")
	if !hasFile(s.visibleFiles(dir), h.file) {
		return ""
	}
	return label.New("", dir, h.target).Rel("", root).String()
}

// linkHookImports is the link hook of the package rooted at root, with its
// imports, named from the repository root, for the deps of lib, the
// package's library; nil when it has none.
func (s *scanState) linkHookImports(repoRoot, root, lib string) []DartFileInfo {
	if s.hookLabel(linkHook, root) == "" {
		return nil
	}
	rel := path.Join(root, "hook", linkHook.file)
	imports, err := ParseDartFile(filepath.Join(repoRoot, filepath.FromSlash(rel)))
	if err != nil {
		log.Printf("dart: %s: %v; its imports are not in %s's deps", rel, err, lib)
		return nil
	}
	return []DartFileInfo{{Path: rel, Imports: imports}}
}

// hookRules is what Gazelle writes in a package's hook/ directory: a
// filegroup holding each hook, visible to the package's root, where its
// metadata is, and nothing for the hooks' imports, which the package
// library's dependencies carry. A `dart_library` of the directory's files,
// which earlier Gazelle versions wrote, is deleted, as is a hook's filegroup
// once the hook is gone.
func hookRules(args language.GenerateArgs, root string) language.GenerateResult {
	var res language.GenerateResult
	gone := map[string]bool{}
	for _, h := range hookKinds {
		if !hasFile(args.RegularFiles, h.file) {
			gone[h.target] = true
			continue
		}
		r := rule.NewRule("filegroup", h.target)
		r.SetAttr("srcs", []string{h.file})
		r.SetAttr("visibility", []string{label.New("", root, "__pkg__").String()})
		res.Gen = append(res.Gen, r)
		res.Imports = append(res.Imports, nil)
	}
	if args.File == nil {
		return res
	}
	for _, r := range args.File.Rules {
		switch {
		case r.Kind() == "filegroup" && gone[r.Name()]:
		case r.Kind() == "dart_library" && ownSources(r, args.RegularFiles):
		default:
			continue
		}
		res.Empty = append(res.Empty, rule.NewRule(r.Kind(), r.Name()))
	}
	return res
}

// ownSources reports whether a rule's srcs are all Dart files of its own
// directory, as a library Gazelle wrote for the directory's files is.
func ownSources(r *rule.Rule, files []string) bool {
	srcs := r.AttrStrings("srcs")
	for _, s := range srcs {
		if path.Ext(s) != ".dart" || !hasFile(files, s) {
			return false
		}
	}
	return len(srcs) > 0
}
