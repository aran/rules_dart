package dart

import (
	"fmt"
	"log"
	"sort"

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

// agreementState collects the disagreements found while generating, so that
// the run reports every one of them and then fails, before it writes any
// BUILD file.
type agreementState struct {
	errors map[string]bool
}

// statement is one place a package fact is stated: its value and where.
type statement struct {
	value, where string
}

// checkAgreement records an error for each fact about the package args.Rel
// belongs to -- its name, its language version -- that two places state
// differently: a `dart_package_metadata` the rules name, a directive, the
// pubspec.yaml at the package's root.
//
// A declaration the rules name is the whole statement, so a pubspec or
// directive version it does not repeat is a disagreement too: the build would
// never read it. Without a declaration, a directive and a pubspec that both
// state a fact must state the same value.
func (d *dartLang) checkAgreement(args language.GenerateArgs) {
	root, err := packageRootOf(args.Rel)
	if err != nil {
		return
	}
	pubName, pubVersion := pubspecFacts(args.Config, root)
	pubspec := pubspecFile(root)
	name := []statement{}
	version := []statement{}
	decl := packageDeclOf(args)
	if decl == nil {
		// A bin/ or test/ directory, in the package declared at its root.
		decl = packageDeclIn(args.Config, root)
	}
	if decl != nil {
		where := "dart_package_metadata " + decl.label()
		name = append(name, statement{decl.PackageName, where})
		version = append(version, statement{decl.LanguageVersion, where})
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
	d.agreement.check(args.Rel, "package name", name)
	d.agreement.check(args.Rel, "language version", version)
}

// check records an error when any statement differs from the first.
func (s *agreementState) check(rel, fact string, stated []statement) {
	for _, other := range stated[min(1, len(stated)):] {
		first := stated[0]
		if other.value == first.value {
			continue
		}
		if s.errors == nil {
			s.errors = map[string]bool{}
		}
		s.errors[fmt.Sprintf(
			"dart: %s: the %s is stated twice, differently: %s by %s, "+
				"%s by %s; state it once, or make the two agree",
			dirName(rel), fact, quoted(first.value), first.where, quoted(other.value), other.where,
		)] = true
	}
}

// DoneGeneratingRules fails the run when any fact disagrees, before
// Gazelle resolves or writes anything.
func (d *dartLang) DoneGeneratingRules() {
	if len(d.agreement.errors) == 0 {
		return
	}
	var msgs []string
	for m := range d.agreement.errors {
		msgs = append(msgs, m)
	}
	sort.Strings(msgs)
	for _, m := range msgs[:len(msgs)-1] {
		log.Print(m)
	}
	log.Fatal(msgs[len(msgs)-1])
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
