package dart

import (
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A test file's `@TestOn('<selector>')` names the platforms package:test
// runs it on; on any other, package:test loads none of its tests and `dart
// test` on the file fails with "No tests were found". Gazelle states the
// same platforms as the test's `target_compatible_with`, so Bazel skips the
// test on a platform it cannot run on instead of failing it.
//
// The selector is evaluated as package:test evaluates it, over the platforms
// a `dart_test` can be built for: the Dart VM on Linux, macOS, Windows or an
// OS package:test does not know, and the web platforms, which carry the
// `@rules_dart//dart/constraints:runtime` value `js` or `wasm` and, as a
// browser does for package:test, no OS. The platforms it accepts become
// constraints a platform must carry. A variable Gazelle cannot map onto
// those platforms (a browser by name, a compiler, `android`), and an
// accepted set no `target_compatible_with` states, fail the run; write the
// attribute by hand and mark it `# keep`.

const incompatible = "@platforms//:incompatible"

// A runtime: `@rules_dart//dart/constraints:<value>`.
var runtimes = []string{"vm", "js", "wasm"}

// An OS: `@platforms//os:<value>`, and "" for any other.
var testOSes = []string{"linux", "macos", "windows", ""}

// testPlatform is one platform a `dart_test` can be built for.
type testPlatform struct{ runtime, os string }

// testPlatforms are the platforms a selector is evaluated over: the VM on
// each OS, and each web platform, which has none.
var testPlatforms = func() []testPlatform {
	var ps []testPlatform
	for _, o := range testOSes {
		ps = append(ps, testPlatform{"vm", o})
	}
	return append(ps, testPlatform{"js", ""}, testPlatform{"wasm", ""})
}()

// selectorVariable is the value of a package:test platform variable on p,
// for each variable Gazelle maps.
func selectorVariable(name string, p testPlatform) (bool, bool) {
	vm := p.runtime == "vm"
	switch name {
	case "vm", "dart-vm":
		return vm, true
	case "browser":
		return !vm, true
	case "js", "wasm":
		return p.runtime == name, true
	case "linux", "windows":
		return vm && p.os == name, true
	case "mac-os":
		return vm && p.os == "macos", true
	case "posix":
		return vm && (p.os == "linux" || p.os == "macos"), true
	}
	return false, false
}

// setTestPlatforms states on r, the `dart_test` of the file f, the
// platforms its `@TestOn` accepts. A problem is an error unless the
// existing rule's `target_compatible_with` is marked `# keep`.
//
// Gazelle's merger merges no select but rules_go's, so the attribute is not
// merged: the existing rule's is removed here, unless marked `# keep`, and
// the merge then copies the new one in.
func (d *dartLang) setTestPlatforms(args language.GenerateArgs, f DartFileInfo, r *rule.Rule) {
	old := ruleIn(args.File, r.Name())
	if old != nil && (old.ShouldKeep() || kept(old, "target_compatible_with")) {
		return
	}
	rel := path.Join(args.Rel, f.Path)
	data, err := os.ReadFile(filepath.Join(args.Dir, f.Path))
	if err != nil {
		d.errs.add(fmt.Sprintf("dart: %s: reading @TestOn: %v", rel, err))
		return
	}
	value, err := testOnCompatibility(string(data))
	if err != nil {
		d.errs.add(fmt.Sprintf("dart: %s: %v; state `target_compatible_with` by "+
			"hand and mark it `# keep`", rel, err))
		return
	}
	if value != nil {
		r.SetAttr("target_compatible_with", value)
	} else if old != nil && old.Attr("target_compatible_with") != nil {
		log.Printf("dart: %s: removing target_compatible_with from %q, which the "+
			"file's @TestOn does not give; mark it `# keep` if it was written by hand",
			rel, r.Name())
	}
	if old != nil {
		old.DelAttr("target_compatible_with")
	}
}

// ruleIn is the rule named name in f, or nil.
func ruleIn(f *rule.File, name string) *rule.Rule {
	if f == nil {
		return nil
	}
	for _, r := range f.Rules {
		if r.Name() == name {
			return r
		}
	}
	return nil
}

// testOnCompatibility is the `target_compatible_with` value for a test
// file's source: nil when it has no `@TestOn` or accepts every platform,
// else a list of constraints or a select of them.
func testOnCompatibility(src string) (interface{}, error) {
	s := stripCommentsOnly(src)
	prefixes := map[string]bool{}
	for _, m := range importPrefixRe.FindAllStringSubmatch(s, -1) {
		prefixes[m[1]] = true
	}
	var args []string
	for _, a := range firstDirectiveAnnotations(s) {
		if annotationClass(a.name, prefixes) == "TestOn" {
			args = append(args, a.args)
		}
	}
	switch {
	case len(args) == 0:
		return nil, nil
	case len(args) > 1:
		return nil, fmt.Errorf("more than one @TestOn annotation; package:test allows one")
	}
	i := skipSpace(args[0], 0)
	text, next, ok := stringLiteral(args[0], i)
	if !ok || strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(args[0][next:]), ",")) != "" {
		return nil, fmt.Errorf("@TestOn is not one string literal, so Gazelle cannot read its platforms")
	}
	sel, err := parseSelector(text)
	if err != nil {
		return nil, fmt.Errorf("@TestOn(%q): %v", text, err)
	}
	var accepted []testPlatform
	for _, p := range testPlatforms {
		if sel(p) {
			accepted = append(accepted, p)
		}
	}
	value, ok := compatibility(accepted)
	if !ok {
		return nil, fmt.Errorf("@TestOn(%q) accepts a set of platforms no "+
			"`target_compatible_with` Gazelle writes states", text)
	}
	return value, nil
}

// compatibility is the `target_compatible_with` that holds on exactly the
// accepted platforms: nil for all of them, and false when none states it.
// It is a product of a condition on the runtime and one on the OS,
// each a constraint or a select, of which at most one is a select; the
// shortest is chosen.
func compatibility(accepted []testPlatform) (interface{}, bool) {
	if len(accepted) == 0 {
		return []string{incompatible}, true
	}
	if len(accepted) == len(testPlatforms) {
		return nil, true
	}
	in := map[testPlatform]bool{}
	for _, p := range accepted {
		in[p] = true
	}
	var best interface{}
	bestCost := -1
	for cm := 1; cm < 1<<len(runtimes); cm++ {
		for om := 1; om < 1<<len(testOSes); om++ {
			match := true
			for _, p := range testPlatforms {
				if (inMask(runtimes, cm, p.runtime) && inMask(testOSes, om, p.os)) != in[p] {
					match = false
					break
				}
			}
			if !match {
				continue
			}
			wc := dimension("@rules_dart//dart/constraints:", runtimes, cm, "vm")
			oc := dimension("@platforms//os:", testOSes, om, "")
			value, cost, ok := product(wc, oc)
			if ok && (bestCost < 0 || cost < bestCost) {
				best, bestCost = value, cost
			}
		}
	}
	return best, bestCost >= 0
}

func inMask(values []string, mask int, v string) bool {
	for i, x := range values {
		if x == v {
			return mask&(1<<i) != 0
		}
	}
	return false
}

// condition is what one dimension requires of a platform: nothing, one
// constraint, or a select on the dimension's constraint values, where a key
// maps to whether a platform carrying it is accepted.
type condition struct {
	constraint string
	keys       map[string]bool
	others     bool // what the select's default accepts
}

// dimension is the condition accepting the values of mask among values,
// each the constraint prefix+value, where dflt is the value a platform
// stating none has ("" for an OS no constraint names).
func dimension(prefix string, values []string, mask int, dflt string) condition {
	if mask == 1<<len(values)-1 {
		return condition{}
	}
	var on []string
	for i, v := range values {
		if mask&(1<<i) != 0 {
			on = append(on, v)
		}
	}
	if len(on) == 1 && on[0] != "" {
		return condition{constraint: prefix + on[0]}
	}
	// A platform stating no value has dflt: the select's default is what
	// that value requires. Where dflt is a value of its own, a constraint
	// value is a key like any other, and the default is what most require.
	others := inMask(values, mask, dflt)
	if dflt != "" && 2*len(on) > len(values) {
		others = true
	} else if dflt != "" {
		others = false
	}
	c := condition{keys: map[string]bool{}, others: others}
	for i, v := range values {
		if v == "" {
			continue
		}
		if accepted := mask&(1<<i) != 0; accepted != c.others {
			c.keys[prefix+v] = accepted
		}
	}
	return c
}

// product is the value requiring both conditions, and its length.
func product(a, b condition) (interface{}, int, bool) {
	if a.keys != nil && b.keys != nil {
		return nil, 0, false
	}
	sel, other := a, b
	if b.keys != nil {
		sel, other = b, a
	}
	var list []string
	for _, c := range []condition{other, sel} {
		if c.constraint != "" {
			list = append(list, c.constraint)
		}
	}
	if sel.keys == nil {
		return list, len(list), true
	}
	branch := func(accepted bool) []string {
		if !accepted {
			return []string{incompatible}
		}
		if other.constraint != "" {
			return []string{other.constraint}
		}
		return []string{}
	}
	value := rule.SelectStringListValue{"//conditions:default": branch(sel.others)}
	for k, accepted := range sel.keys {
		value[k] = branch(accepted)
	}
	cost := 1 + len(sel.keys)
	if other.constraint != "" {
		cost++
	}
	return value, cost, true
}

// parseSelector parses a package:test platform selector (package
// boolean_selector's grammar: `||`, `&&`, `!`, `?:`, parentheses and
// hyphenated identifiers) into its evaluation on a platform.
func parseSelector(text string) (selectorExpr, error) {
	p := &selectorParser{s: text}
	e, err := p.conditional()
	if err != nil {
		return nil, err
	}
	if p.skip(); p.i < len(p.s) {
		return nil, fmt.Errorf("unexpected %q", p.s[p.i:])
	}
	return e, nil
}

type selectorParser struct {
	s string
	i int
}

type selectorExpr = func(testPlatform) bool

func (p *selectorParser) skip() {
	for p.i < len(p.s) && strings.ContainsRune(" \t\r\n", rune(p.s[p.i])) {
		p.i++
	}
}

func (p *selectorParser) eat(tok string) bool {
	p.skip()
	if strings.HasPrefix(p.s[p.i:], tok) {
		p.i += len(tok)
		return true
	}
	return false
}

func (p *selectorParser) conditional() (selectorExpr, error) {
	cond, err := p.or()
	if err != nil || !p.eat("?") {
		return cond, err
	}
	then, err := p.conditional()
	if err != nil {
		return nil, err
	}
	if !p.eat(":") {
		return nil, fmt.Errorf("expected ':'")
	}
	els, err := p.conditional()
	if err != nil {
		return nil, err
	}
	return func(t testPlatform) bool {
		if cond(t) {
			return then(t)
		}
		return els(t)
	}, nil
}

func (p *selectorParser) or() (selectorExpr, error) {
	return p.binary("||", p.and, true)
}

func (p *selectorParser) and() (selectorExpr, error) {
	return p.binary("&&", p.not, false)
}

// binary parses operands joined by op, which is `||` when or, else `&&`.
func (p *selectorParser) binary(op string, operand func() (selectorExpr, error), or bool) (selectorExpr, error) {
	left, err := operand()
	if err != nil {
		return nil, err
	}
	for p.eat(op) {
		right, err := operand()
		if err != nil {
			return nil, err
		}
		l := left
		left = func(t testPlatform) bool {
			if or {
				return l(t) || right(t)
			}
			return l(t) && right(t)
		}
	}
	return left, nil
}

func (p *selectorParser) not() (selectorExpr, error) {
	if p.eat("!") {
		e, err := p.not()
		if err != nil {
			return nil, err
		}
		return func(t testPlatform) bool { return !e(t) }, nil
	}
	if p.eat("(") {
		e, err := p.conditional()
		if err != nil {
			return nil, err
		}
		if !p.eat(")") {
			return nil, fmt.Errorf("expected ')'")
		}
		return e, nil
	}
	p.skip()
	start := p.i
	for p.i < len(p.s) && (isIdentChar(p.s[p.i]) || p.s[p.i] == '-') {
		p.i++
	}
	name := p.s[start:p.i]
	if name == "" {
		return nil, fmt.Errorf("expected a variable at %q", p.s[start:])
	}
	if _, ok := selectorVariable(name, testPlatform{}); !ok {
		return nil, fmt.Errorf("Gazelle maps the variables vm, dart-vm, browser, "+
			"js, wasm, linux, mac-os, windows and posix onto Bazel platforms, "+
			"not %q", name)
	}
	return func(t testPlatform) bool {
		v, _ := selectorVariable(name, t)
		return v
	}, nil
}
