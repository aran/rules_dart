package dart

import (
	"log"
	"path"

	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/bazel-gazelle/walk"
)

// A package's hook/build.dart builds native code when pub gets the package.
// rules_dart never runs it, and fails every binary and test that reaches a
// library stating it in `build_hook` unless that library's `code_assets`
// replace what it builds. So Gazelle states it, on the library of the
// package's lib/ directory, and the build says what to do; a package whose
// hook's native code is unused has Gazelle not see the file, with
// `# gazelle:exclude hook/build.dart`.

const (
	buildHookFile   = "build.dart"
	buildHookTarget = "build"
)

// visibleFiles is the regular files of directory rel that Gazelle sees:
// those no `# gazelle:exclude` excludes. Nil when the directory is absent.
func visibleFiles(rel string) []string {
	di, err := walk.GetDirInfo(rel)
	if err != nil {
		return nil
	}
	return di.RegularFiles
}

func hasFile(files []string, name string) bool {
	for _, f := range files {
		if f == name {
			return true
		}
	}
	return false
}

// buildHookLabel is the label, relative to directory from, of the build hook
// of the package rooted at root, or "" when it has none Gazelle sees.
func buildHookLabel(root, from string) string {
	dir := path.Join(root, "hook")
	if !hasFile(visibleFiles(dir), buildHookFile) {
		return ""
	}
	return label.New("", dir, buildHookTarget).Rel("", from).String()
}

// logUnstatedBuildHook says when a package has a build hook and Gazelle
// writes no library of its lib/ to state it on.
func logUnstatedBuildHook(root string) {
	if buildHookLabel(root, "") == "" {
		return
	}
	log.Printf("dart: %s has a build hook and %s holds no library Gazelle writes "+
		"to state it on; give a hand-written `dart_library` of the package "+
		"`build_hook = %q`", path.Join(root, "hook", buildHookFile), libDirOf(root),
		label.New("", path.Join(root, "hook"), buildHookTarget).String())
}

// hookRules is what Gazelle writes in a package's hook/ directory: the
// filegroup holding its build hook, visible to the package's lib/, and
// nothing for the hook's imports, since nothing builds it. A `dart_library`
// of the directory's files, which earlier Gazelle versions wrote, is deleted,
// as is the filegroup once the hook is gone.
func hookRules(args language.GenerateArgs, root string) language.GenerateResult {
	var res language.GenerateResult
	has := hasFile(args.RegularFiles, buildHookFile)
	if has {
		r := rule.NewRule("filegroup", buildHookTarget)
		r.SetAttr("srcs", []string{buildHookFile})
		r.SetAttr("visibility", []string{label.New("", libDirOf(root), "__pkg__").String()})
		res.Gen = append(res.Gen, r)
		res.Imports = append(res.Imports, nil)
	}
	if args.File == nil {
		return res
	}
	for _, r := range args.File.Rules {
		switch {
		case r.Kind() == "filegroup" && r.Name() == buildHookTarget && !has:
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
