package dart

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/rule"
)

// A test file's suite-level tags come from package:test's `@Tags([...])`.
// package:test reads them, with its other suite metadata, from the
// annotations on the file's first directive (`library`, `import`, `export`
// or `part`), so this does the same: annotations ahead of a declaration, or
// in a file with no directives, carry no suite metadata. The annotation is
// recognised by name, as package:test does, bare or behind an import prefix.

// dartTagRe is package:test's rule for a tag name: an optionally hyphenated
// Dart identifier. package:test refuses a file whose @Tags break it.
var dartTagRe = regexp.MustCompile(`^[a-zA-Z_-][a-zA-Z0-9_-]*$`)

// importPrefixRe captures the `as` prefix of an import directive, after any
// `deferred` keyword or configurable-import clauses.
var importPrefixRe = regexp.MustCompile(
	`\bimport\s+(?:'[^']*'|"[^"]*")[^;]*?\bas\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*;`)

// bazelReservedTag reports whether Bazel gives the tag a meaning of its own:
// test scheduling (`manual`, `exclusive`, `external`, `local`) or an
// execution requirement (every tag Bazel copies into an action's execution
// info). Passing such a Dart tag through would silently change how the test
// runs.
func bazelReservedTag(tag string) bool {
	switch tag {
	case "manual", "exclusive", "exclusive-if-local", "external", "local",
		"worker-key-mnemonic":
		return true
	}
	for _, p := range []string{"no-", "requires-", "supports-", "disable-", "block-network"} {
		if strings.HasPrefix(tag, p) {
			return true
		}
	}
	return false
}

// ParseDartTestTags reads the suite-level `@Tags` of the test file at path.
// It returns the tags to copy onto the Bazel target, sorted and unique, and
// a description of each problem that kept a tag (or the whole annotation)
// out.
func ParseDartTestTags(path string) ([]string, []string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	tags, problems := testTagsFromSource(string(data))
	return tags, problems, nil
}

// testTagsFromSource is ParseDartTestTags over source text.
func testTagsFromSource(src string) ([]string, []string) {
	s := stripCommentsOnly(src)
	prefixes := map[string]bool{}
	for _, m := range importPrefixRe.FindAllStringSubmatch(s, -1) {
		prefixes[m[1]] = true
	}

	var tagArgs []string
	for _, a := range firstDirectiveAnnotations(s) {
		if annotationClass(a.name, prefixes) == "Tags" {
			tagArgs = append(tagArgs, a.args)
		}
	}
	switch {
	case len(tagArgs) == 0:
		return nil, nil
	case len(tagArgs) > 1:
		return nil, []string{"more than one @Tags annotation; package:test allows one"}
	}

	values, ok := literalStringList(tagArgs[0])
	if !ok {
		return nil, []string{"@Tags is not a list of string literals, so its tags can't be read without running Dart; none are copied"}
	}
	var problems []string
	seen := map[string]bool{}
	var tags []string
	for _, v := range values {
		switch {
		case !dartTagRe.MatchString(v):
			problems = append(problems, fmt.Sprintf("tag %q is not a valid package:test tag name; not copied", v))
		case bazelReservedTag(v):
			problems = append(problems, fmt.Sprintf("tag %q means something to Bazel and would change how the test runs; not copied (rename the Dart tag, or write the Bazel tag by hand with `# keep`)", v))
		case !seen[v]:
			seen[v] = true
			tags = append(tags, v)
		}
	}
	sort.Strings(tags)
	return tags, problems
}

type dartAnnotation struct {
	name []string // dotted name, split
	args string   // text between the parentheses; "" without any
}

// firstDirectiveAnnotations returns the annotations leading the file when
// they are attached to a directive, the ones package:test reads suite
// metadata from. s has comments stripped.
func firstDirectiveAnnotations(s string) []dartAnnotation {
	i := 0
	if strings.HasPrefix(s, "#!") {
		for i < len(s) && s[i] != '\n' {
			i++
		}
	}
	var anns []dartAnnotation
	for {
		i = skipSpace(s, i)
		if i >= len(s) {
			return nil
		}
		if s[i] != '@' {
			break
		}
		i++
		var a dartAnnotation
		for {
			i = skipSpace(s, i)
			start := i
			for i < len(s) && isIdentChar(s[i]) {
				i++
			}
			if i == start {
				return nil
			}
			a.name = append(a.name, s[start:i])
			j := skipSpace(s, i)
			if j < len(s) && s[j] == '.' {
				i = j + 1
				continue
			}
			break
		}
		// Optional type arguments, then the argument list.
		j := skipSpace(s, i)
		if j < len(s) && s[j] == '<' {
			end := matchingClose(s, j, '<', '>')
			if end < 0 {
				return nil
			}
			j = skipSpace(s, end+1)
		}
		if j < len(s) && s[j] == '(' {
			end := matchingClose(s, j, '(', ')')
			if end < 0 {
				return nil
			}
			a.args = s[j+1 : end]
			i = end + 1
		}
		anns = append(anns, a)
	}
	start := i
	for i < len(s) && isIdentChar(s[i]) {
		i++
	}
	switch s[start:i] {
	case "library", "import", "export", "part":
		return anns
	}
	return nil
}

// annotationClass names the class an annotation constructs, resolving the
// `a.B` ambiguity the way package:test does: `a` is an import prefix if
// some import declares it, otherwise a class with named constructor `B`.
func annotationClass(name []string, prefixes map[string]bool) string {
	switch len(name) {
	case 1:
		return name[0]
	case 2:
		if prefixes[name[0]] {
			return name[1]
		}
		return name[0]
	case 3:
		return name[1]
	}
	return ""
}

// literalStringList reads the first argument of args as a list literal of
// string literals (`[...]`, optionally `const` and `<String>`-typed). It
// reports false for anything else, including an interpolated or escaped
// string, whose value it does not compute.
func literalStringList(args string) ([]string, bool) {
	i := skipSpace(args, 0)
	if strings.HasPrefix(args[i:], "const") && (i+5 == len(args) || !isIdentChar(args[i+5])) {
		i = skipSpace(args, i+5)
	}
	if i < len(args) && args[i] == '<' {
		end := matchingClose(args, i, '<', '>')
		if end < 0 {
			return nil, false
		}
		i = skipSpace(args, end+1)
	}
	if i >= len(args) || args[i] != '[' {
		return nil, false
	}
	i++
	var out []string
	for {
		i = skipSpace(args, i)
		if i >= len(args) {
			return nil, false
		}
		if args[i] == ']' {
			return out, true
		}
		// One element: adjacent string literals concatenate.
		var b strings.Builder
		n := 0
		for {
			i = skipSpace(args, i)
			v, next, ok := stringLiteral(args, i)
			if !ok {
				break
			}
			b.WriteString(v)
			i = next
			n++
		}
		if n == 0 {
			return nil, false
		}
		out = append(out, b.String())
		i = skipSpace(args, i)
		if i < len(args) && args[i] == ',' {
			i++
			continue
		}
		if i < len(args) && args[i] == ']' {
			return out, true
		}
		return nil, false
	}
}

// stringLiteral reads one Dart string literal at s[i:] whose value is its
// text: raw, or free of interpolation and escapes.
func stringLiteral(s string, i int) (string, int, bool) {
	raw := false
	if i < len(s) && s[i] == 'r' {
		raw = true
		i++
	}
	if i >= len(s) || (s[i] != '\'' && s[i] != '"') {
		return "", 0, false
	}
	delim := s[i : i+1]
	if strings.HasPrefix(s[i:], strings.Repeat(delim, 3)) {
		delim = strings.Repeat(delim, 3)
	}
	i += len(delim)
	end := strings.Index(s[i:], delim)
	if end < 0 {
		return "", 0, false
	}
	v := s[i : i+end]
	if !raw && strings.ContainsAny(v, `$\`) {
		return "", 0, false
	}
	return v, i + end + len(delim), true
}

// matchingClose returns the index of the bracket closing the one at s[i],
// skipping string literals, or -1.
func matchingClose(s string, i int, open, close byte) int {
	depth := 0
	for ; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\'' || c == '"':
			delim := s[i : i+1]
			if strings.HasPrefix(s[i:], strings.Repeat(delim, 3)) {
				delim = strings.Repeat(delim, 3)
			}
			j := i + len(delim)
			for j < len(s) && !strings.HasPrefix(s[j:], delim) {
				if s[j] == '\\' {
					j++
				}
				j++
			}
			if j >= len(s) {
				return -1
			}
			i = j + len(delim) - 1
		case c == open:
			depth++
		case c == close:
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

func skipSpace(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

// droppedHandTags returns the tags an existing rule has that the merge will
// remove: not generated this pass and not protected by `# keep` on the rule,
// the attribute or the value. Gazelle cannot tell a tag a previous run copied
// from @Tags from one a person wrote, so these are reported, not guessed at.
func droppedHandTags(existing *rule.Rule, generated []string) []string {
	if existing == nil || existing.ShouldKeep() || existing.Attr("tags") == nil {
		return nil
	}
	if c := existing.AttrComments("tags"); c != nil {
		for _, cm := range append(c.Before, c.Suffix...) {
			text := strings.TrimSpace(strings.TrimPrefix(cm.Token, "#"))
			if text == "keep" || strings.HasPrefix(text, "keep: ") {
				return nil
			}
		}
	}
	keep := map[string]bool{}
	for _, t := range generated {
		keep[t] = true
	}
	// MergeList against an empty source keeps exactly the `# keep` values.
	if kept := rule.MergeList(nil, existing.Attr("tags")); kept != nil {
		tmp := rule.NewRule("", "")
		tmp.SetAttr("tags", kept)
		for _, t := range tmp.AttrStrings("tags") {
			keep[t] = true
		}
	}
	var dropped []string
	for _, t := range existing.AttrStrings("tags") {
		if !keep[t] {
			dropped = append(dropped, t)
		}
	}
	return dropped
}
