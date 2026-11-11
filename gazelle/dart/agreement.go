package dart

import (
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
)

// The directives that state a fact about the package of the directory they
// are in, and of the directories below it.
const (
	keyPackageName     = "dart_package_name"
	keyLanguageVersion = "dart_language_version"
)

// directiveValue is a directive's value and the BUILD file, repo-relative,
// that states it.
type directiveValue struct {
	Value, File string
}

// scopePackageFacts keeps the package-fact directives of a package out of a
// package rooted inside it at rel (`placeOf`), as upstream each package's
// own pubspec.yaml states its facts: a directive applies to the directory
// whose BUILD file states it and those below it, within its package.
func scopePackageFacts(c *config.Config, rel string) {
	if p := placeOf(c, rel); p.Err != nil || p.Root != rel {
		return
	}
	for _, key := range []string{keyPackageName, keyLanguageVersion} {
		delete(c.Exts, key)
	}
}

// directiveFact is the directive value in force for key, or nil.
func directiveFact(c *config.Config, key string) *directiveValue {
	if c.Exts == nil {
		return nil
	}
	if v, ok := c.Exts[key].(*directiveValue); ok && v.Value != "" {
		return v
	}
	return nil
}

// generationErrors collects the problems found while generating -- facts
// stated differently in two places, a build.yaml Gazelle cannot carry into
// the build -- so that the run reports every one of them and then fails,
// before it writes any BUILD file.
type generationErrors struct {
	mu     sync.Mutex
	errors map[string]bool
}

// add records an error; the same one recorded twice is reported once.
func (s *generationErrors) add(msg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.errors == nil {
		s.errors = map[string]bool{}
	}
	s.errors[msg] = true
}

// statement is one place a package fact is stated: its value and where.
type statement struct {
	value, where string
}

// checkAgreement records an error for each fact about the package args.Rel
// belongs to -- its name, its language version -- that two places state
// differently: a directive, the pubspec.yaml at the package's root, and an
// attribute of the package's `dart_package_metadata` marked `# keep`.
//
// The metadata's attributes are what Gazelle writes from the directive and
// the pubspec, so one that differs is rewritten, not a disagreement; one
// marked `# keep` Gazelle leaves as it is, so the build would carry the
// difference.
func (d *dartLang) checkAgreement(args language.GenerateArgs) {
	root, err := packageRootOf(args.Config, args.Rel)
	if err != nil {
		return
	}
	pubName, pubVersion := pubspecFacts(args.Config, root)
	pubspec := pubspecFile(root)
	name := []statement{}
	version := []statement{}
	if decl := packageDeclAt(args.Config, root); decl != nil {
		if len(decl.Others) > 0 && args.Rel == root {
			d.errs.add(fmt.Sprintf(
				"dart: %s: the BUILD file declares the package with more than one dart_package_metadata (%s); a package has one",
				dirName(args.Rel), strings.Join(append([]string{decl.Name}, decl.Others...), ", "),
			))
		}
		where := "dart_package_metadata " + decl.label() + " (`# keep`)"
		if decl.KeepName {
			name = append(name, statement{decl.PackageName, where})
		}
		if decl.KeepVersion {
			version = append(version, statement{decl.LanguageVersion, where})
		}
	}
	if f := directiveFact(args.Config, keyPackageName); f != nil {
		name = append(name, statement{f.Value, "`# gazelle:" + keyPackageName + "` in " + f.File})
	}
	if f := directiveFact(args.Config, keyLanguageVersion); f != nil {
		version = append(version, statement{f.Value, "`# gazelle:" + keyLanguageVersion + "` in " + f.File})
	}
	if pubName != "" {
		name = append(name, statement{pubName, pubspec})
	}
	if pubVersion != "" {
		version = append(version, statement{pubVersion, pubspec})
	}
	d.errs.check(args.Rel, "package name", name)
	d.errs.check(args.Rel, "language version", version)
}

// check records an error when any statement differs from the first.
func (s *generationErrors) check(rel, fact string, stated []statement) {
	for _, other := range stated[min(1, len(stated)):] {
		first := stated[0]
		if other.value == first.value {
			continue
		}
		s.add(fmt.Sprintf(
			"dart: %s: the %s is stated twice, differently: %s by %s, "+
				"%s by %s; state it once, or make the two agree",
			dirName(rel), fact, quoted(first.value), first.where, quoted(other.value), other.where,
		))
	}
}

// DoneGeneratingRules fails the run when generating found any problem,
// before Gazelle resolves or writes anything.
func (d *dartLang) DoneGeneratingRules() {
	d.cycles.check(&d.errs)
	if len(d.errs.errors) == 0 {
		return
	}
	var msgs []string
	for m := range d.errs.errors {
		msgs = append(msgs, m)
	}
	sort.Slice(msgs, func(i, j int) bool { return naturalLess(msgs[i], msgs[j]) })
	for _, m := range msgs[:len(msgs)-1] {
		log.Print(m)
	}
	log.Fatal(msgs[len(msgs)-1])
}

// naturalLess orders a before b as text, but a run of digits by its number,
// so that `build.yaml:9` comes before `build.yaml:13`.
func naturalLess(a, b string) bool {
	for a != "" && b != "" {
		da, db := digitRun(a), digitRun(b)
		if da > 0 && db > 0 {
			na, nb := strings.TrimLeft(a[:da], "0"), strings.TrimLeft(b[:db], "0")
			if len(na) != len(nb) {
				return len(na) < len(nb)
			}
			if na != nb {
				return na < nb
			}
			a, b = a[da:], b[db:]
			continue
		}
		if a[0] != b[0] {
			return a[0] < b[0]
		}
		a, b = a[1:], b[1:]
	}
	return len(a) < len(b)
}

// digitRun is the length of the run of ASCII digits s starts with.
func digitRun(s string) int {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n++
	}
	return n
}

func quoted(v string) string {
	if v == "" {
		return "none"
	}
	return fmt.Sprintf("%q", v)
}

func dirName(rel string) string {
	if rel == "" {
		return "."
	}
	return rel
}
