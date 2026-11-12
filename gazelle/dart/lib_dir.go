package dart

import (
	"context"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A package's library is in the BUILD file at its root and holds every file
// under its lib/ (package_scan.go), so no BUILD file may be under lib/:
// Bazel stops a package's sources at the next BUILD file down. Earlier
// Gazelle versions wrote one for each directory there. Gazelle removes the
// rules it wrote in one, and in fix mode, once it has written every other
// file, deletes the file. A BUILD file there holding anything else is an
// error naming it, since deleting it would lose what it holds.

// staleBuildFiles holds the BUILD files under a package's lib/ that Gazelle
// deletes once it has written the others.
type staleBuildFiles struct {
	mu    sync.Mutex
	files []string // absolute
}

// libDirRules is what Gazelle writes in a directory under the lib/ of the
// package rooted at root, lib/ included: nothing. An existing BUILD file
// there loses every rule and is deleted (staleBuildFiles), or, when it holds
// what Gazelle did not write, is an error.
func (d *dartLang) libDirRules(args language.GenerateArgs, root string) language.GenerateResult {
	f := args.File
	if f == nil {
		return language.GenerateResult{}
	}
	deletable := deletableKinds(d.builders())
	var own []string
	for _, r := range f.Rules {
		if !gazelleLibRule(r, args.Rel, deletable) {
			own = append(own, fmt.Sprintf("%s `%s`", r.Kind(), r.Name()))
			continue
		}
		for _, attr := range handAttrs(r, d.Kinds()) {
			own = append(own, fmt.Sprintf("`%s` on %s `%s`", attr, r.Kind(), r.Name()))
		}
	}
	for _, dir := range f.Directives {
		own = append(own, "`# gazelle:"+dir.Key+"`")
	}
	if len(own) > 0 {
		d.errs.add(fmt.Sprintf(
			"dart: %s holds %s, which Gazelle did not write; the package's "+
				"`dart_library` in %s holds every file under lib/, which a BUILD "+
				"file under lib/ would cut off, so move what it holds there and "+
				"delete it",
			path.Join(args.Rel, filepath.Base(f.Path)), strings.Join(own, ", "),
			path.Join(root, "BUILD.bazel")))
		return language.GenerateResult{}
	}
	var res language.GenerateResult
	for _, r := range f.Rules {
		res.Empty = append(res.Empty, rule.NewRule(r.Kind(), r.Name()))
	}
	if d.mode == "" || d.mode == "fix" {
		d.stale.mu.Lock()
		d.stale.files = append(d.stale.files, f.Path)
		d.stale.mu.Unlock()
	} else {
		d.errs.add(fmt.Sprintf(
			"dart: %s is under the package's lib/, whose files the package's "+
				"`dart_library` in %s holds; Gazelle deletes it when run in fix mode",
			path.Join(args.Rel, filepath.Base(f.Path)), path.Join(root, "BUILD.bazel")))
	}
	return res
}

// gazelleLibRule reports whether a rule under lib/ is one Gazelle wrote
// in directory rel: a library, a codegen target or the `filegroup` named for
// the directory, not marked `# keep`.
func gazelleLibRule(r *rule.Rule, rel string, deletable map[string]bool) bool {
	if r.ShouldKeep() {
		return false
	}
	switch {
	case r.Kind() == "dart_library", deletable[r.Kind()]:
		return true
	case r.Kind() == "filegroup":
		return r.Name() == path.Base(rel)
	}
	return false
}

// handAttrs is the attributes of r, a rule of a kind Gazelle writes, that
// Gazelle does not manage or that are marked `# keep`: what was written by
// hand, such as a library's `code_assets`.
func handAttrs(r *rule.Rule, kinds map[string]rule.KindInfo) []string {
	managed := kinds[r.Kind()].MergeableAttrs
	var out []string
	for _, k := range r.AttrKeys() {
		// A library's code_assets Gazelle moves onto the metadata only from
		// the package's root.
		if k != "name" && k != "visibility" && (!managed[k] || k == "code_assets") || kept(r, k) {
			out = append(out, k)
		}
	}
	return out
}

// kept reports whether r marks attr `# keep`.
func kept(r *rule.Rule, attr string) bool {
	cs := r.AttrComments(attr)
	if cs == nil {
		return false
	}
	for _, c := range append(cs.Before, cs.Suffix...) {
		if strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(c.Token, "#")), "keep") {
			return true
		}
	}
	return false
}

// Before is called before Gazelle generates anything.
func (d *dartLang) Before(ctx context.Context) {}

// AfterResolvingDeps deletes the BUILD files under a package's lib/ that
// Gazelle emptied, once it has written every file. A file that is not empty
// after all, because another language wrote rules into it, is logged and
// left.
func (d *dartLang) AfterResolvingDeps(ctx context.Context) {
	d.stale.mu.Lock()
	defer d.stale.mu.Unlock()
	sort.Strings(d.stale.files)
	for _, p := range d.stale.files {
		f, err := rule.LoadFile(p, "")
		if err != nil {
			log.Printf("dart: %s: %v", p, err)
			continue
		}
		if len(f.Rules) > 0 {
			log.Printf("dart: %s holds rules of another language; it is under "+
				"a package's lib/, so move them out and delete it", p)
			continue
		}
		if err := os.Remove(p); err != nil {
			log.Printf("dart: deleting %s: %v", p, err)
		}
	}
	d.stale.files = nil
}
