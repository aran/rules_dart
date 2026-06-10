package dart

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// DartImport represents a parsed Dart import statement.
type DartImport struct {
	URI       string // The import URI (e.g., "package:foo/bar.dart", "dart:core")
	IsPackage bool   // True if package: import
	IsDartSDK bool   // True if dart: import
	IsRelative bool  // True if relative import (no scheme)
	Package   string // Package name for package: imports
	Path      string // Path within package (e.g., "bar.dart")
}

var importRe = regexp.MustCompile(`^\s*(?:import|export)\s+['"](.+?)['"]`)

// condLineRe detects continuation lines: indented "if (" clauses.
var condLineRe = regexp.MustCompile(`^\s+if\s*\(`)

// condURIRe extracts URIs from "if (condition) 'uri'" clauses.
var condURIRe = regexp.MustCompile(`if\s*\([^)]+\)\s+['"](.+?)['"]`)

// classifyURI parses a URI string into a classified DartImport.
func classifyURI(uri string) DartImport {
	imp := DartImport{URI: uri}
	if strings.HasPrefix(uri, "dart:") {
		imp.IsDartSDK = true
	} else if strings.HasPrefix(uri, "package:") {
		imp.IsPackage = true
		rest := strings.TrimPrefix(uri, "package:")
		parts := strings.SplitN(rest, "/", 2)
		imp.Package = parts[0]
		if len(parts) > 1 {
			imp.Path = parts[1]
		}
	} else {
		imp.IsRelative = true
		imp.Path = uri
	}
	return imp
}

// ParseDartFile extracts import/export URIs from a Dart source file,
// including conditional import/export branch URIs.
func ParseDartFile(path string) ([]DartImport, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(data), "\n")
	var imports []DartImport

	for i := 0; i < len(lines); i++ {
		line := lines[i]
		m := importRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		// Primary URI
		imports = append(imports, classifyURI(m[1]))

		// Conditional URIs on the same line (single-line form)
		for _, cm := range condURIRe.FindAllStringSubmatch(line, -1) {
			imports = append(imports, classifyURI(cm[1]))
		}

		// Lookahead: consume indented "if (...)" continuation lines
		for i+1 < len(lines) && condLineRe.MatchString(lines[i+1]) {
			i++
			for _, cm := range condURIRe.FindAllStringSubmatch(lines[i], -1) {
				imports = append(imports, classifyURI(cm[1]))
			}
		}
	}
	return imports, nil
}

// ParsePubspecName reads pubspec.yaml in dir and returns the package name,
// or "" if not found.
func ParsePubspecName(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, "pubspec.yaml"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "name:") {
			name := strings.TrimSpace(strings.TrimPrefix(line, "name:"))
			name = strings.Trim(name, "\"'")
			return name
		}
	}
	return ""
}

// FindPubspecName walks up from dir toward the repo root looking for
// pubspec.yaml. rel is the workspace-relative path of dir; it bounds the
// upward search so we never look above the repo root.
func FindPubspecName(dir string, rel string) string {
	current := dir
	remaining := rel
	for {
		if name := ParsePubspecName(current); name != "" {
			return name
		}
		if remaining == "" || remaining == "." {
			break
		}
		remaining = filepath.Dir(remaining)
		if remaining == "." {
			remaining = ""
		}
		current = filepath.Dir(current)
	}
	return ""
}

// ParsePubspecLanguageVersion reads pubspec.yaml in dir and derives the
// Dart language version from the `environment.sdk` constraint's lower
// bound. Returns `""` when the file is absent or the constraint can't
// be parsed.
//
// Examples:
//   environment: { sdk: ">=3.11.0 <4.0.0" } → "3.11"
//   environment: { sdk: "^3.10.0" }         → "3.10"
//   environment: { sdk: ">=2.18.0 <3.0.0" } → "2.18"
func ParsePubspecLanguageVersion(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, "pubspec.yaml"))
	if err != nil {
		return ""
	}
	return languageVersionFromPubspec(string(data))
}

// languageVersionFromPubspec extracts the language version from raw
// pubspec.yaml content. Split out for testability.
func languageVersionFromPubspec(content string) string {
	var inEnvironment bool
	for _, raw := range strings.Split(content, "\n") {
		// Strip trailing comments.
		if hash := strings.IndexByte(raw, '#'); hash >= 0 {
			raw = raw[:hash]
		}
		stripped := strings.TrimRight(raw, " \t\r")
		if stripped == "" {
			continue
		}
		if !strings.HasPrefix(stripped, " ") && !strings.HasPrefix(stripped, "\t") {
			// A new top-level key starts; exit the `environment` block.
			inEnvironment = strings.HasPrefix(stripped, "environment:")
			// Single-line flow form: `environment: {sdk: ">=3.11.0 <4.0.0"}`.
			if inEnvironment {
				trailing := strings.TrimSpace(
					strings.TrimPrefix(stripped, "environment:"))
				if trailing != "" {
					if lv := extractSdkLowerBound(trailing); lv != "" {
						return lv
					}
				}
			}
			continue
		}
		if !inEnvironment {
			continue
		}
		trimmed := strings.TrimSpace(stripped)
		if strings.HasPrefix(trimmed, "sdk:") {
			constraint := strings.TrimSpace(strings.TrimPrefix(trimmed, "sdk:"))
			constraint = strings.Trim(constraint, `"'`)
			if lv := extractSdkLowerBound(constraint); lv != "" {
				return lv
			}
		}
	}
	return ""
}

// extractSdkLowerBound parses a pub sdk constraint string and returns the
// lower-bound version in `major.minor` form. Handles `>=X.Y.Z`,
// `^X.Y.Z`, bare `X.Y.Z`, and flow-mapping fragments like
// `{sdk: ">=3.11.0 <4.0.0"}`.
func extractSdkLowerBound(s string) string {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "{")
	s = strings.TrimSuffix(s, "}")
	// Flow-mapping `sdk: "..."`; strip the leading `sdk:` if present.
	if strings.HasPrefix(s, "sdk:") {
		s = strings.TrimSpace(s[len("sdk:"):])
		s = strings.Trim(s, `"'`)
	}
	// Pub constraints are whitespace-separated; iterate over each token
	// and pick the one that looks like a lower-bound version.
	for _, tok := range strings.Fields(s) {
		tok = strings.Trim(tok, `"',`)
		if tok == "" {
			continue
		}
		// Strip operator prefix.
		for _, prefix := range []string{">=", ">", "^", "="} {
			if strings.HasPrefix(tok, prefix) {
				tok = tok[len(prefix):]
				break
			}
		}
		// Skip upper bounds.
		if strings.HasPrefix(tok, "<") {
			continue
		}
		if lv := majorMinor(tok); lv != "" {
			return lv
		}
	}
	return ""
}

// majorMinor returns the `major.minor` prefix of a semver string, or ""
// when the string isn't shaped like a version.
func majorMinor(s string) string {
	// Strip pre-release / build metadata suffix.
	for _, sep := range []string{"-", "+"} {
		if i := strings.Index(s, sep); i >= 0 {
			s = s[:i]
		}
	}
	parts := strings.Split(s, ".")
	if len(parts) < 2 {
		return ""
	}
	for _, seg := range parts[:2] {
		if seg == "" {
			return ""
		}
		for _, c := range seg {
			if c < '0' || c > '9' {
				return ""
			}
		}
	}
	return parts[0] + "." + parts[1]
}

// FindPubspecLanguageVersion walks up from dir toward the repo root
// looking for a pubspec.yaml with an `environment.sdk` constraint. Same
// search semantics as `FindPubspecName`.
func FindPubspecLanguageVersion(dir string, rel string) string {
	current := dir
	remaining := rel
	for {
		if lv := ParsePubspecLanguageVersion(current); lv != "" {
			return lv
		}
		if remaining == "" || remaining == "." {
			break
		}
		remaining = filepath.Dir(remaining)
		if remaining == "." {
			remaining = ""
		}
		current = filepath.Dir(current)
	}
	return ""
}

// DartFileInfo holds metadata about a Dart source file.
type DartFileInfo struct {
	Path    string       // Relative path from package root
	Imports []DartImport // Parsed imports
}

// ParseDartDir scans a directory for Dart files and parses their imports.
func ParseDartDir(dir string, files []string) ([]DartFileInfo, error) {
	var result []DartFileInfo
	for _, name := range files {
		if !strings.HasSuffix(name, ".dart") {
			continue
		}
		fullPath := filepath.Join(dir, name)
		imports, err := ParseDartFile(fullPath)
		if err != nil {
			continue // Skip files that can't be parsed
		}
		result = append(result, DartFileInfo{
			Path:    name,
			Imports: imports,
		})
	}
	return result, nil
}

// stripCommentsAndStrings replaces line/block comments and string literals
// in a Dart source with whitespace, preserving line positions. This lets a
// regex scan for syntactic constructs (annotations, directives) without
// false positives inside comments or strings.
func stripCommentsAndStrings(src string) string {
	var b strings.Builder
	b.Grow(len(src))

	i := 0
	for i < len(src) {
		c := src[i]

		// Triple-quoted strings: """ ... """ or ''' ... '''.
		if (c == '"' || c == '\'') && i+2 < len(src) && src[i+1] == c && src[i+2] == c {
			quote := c
			b.WriteString("   ")
			i += 3
			for i+2 < len(src) && !(src[i] == quote && src[i+1] == quote && src[i+2] == quote) {
				if src[i] == '\n' {
					b.WriteByte('\n')
				} else {
					b.WriteByte(' ')
				}
				i++
			}
			if i+2 < len(src) {
				b.WriteString("   ")
				i += 3
			}
			continue
		}

		// Single/double-quoted string (handles raw r'...' / r"..." and \-escapes).
		if c == '"' || c == '\'' {
			quote := c
			b.WriteByte(' ')
			i++
			// Raw-string prefix is a standalone `r` before the quote —
			// the character *before* the quote must be `r` AND that `r`
			// must not itself be the tail of an identifier (e.g.
			// `filter('...')` must not trip this). `src[i-2]` is the
			// pre-quote byte (since we just incremented i past the
			// quote); `src[i-3]` is the byte before that.
			isRaw := i >= 2 && src[i-2] == 'r' &&
				(i < 3 || !isIdentChar(src[i-3]))
			for i < len(src) && src[i] != quote {
				if src[i] == '\\' && !isRaw && i+1 < len(src) {
					b.WriteByte(' ')
					b.WriteByte(' ')
					i += 2
					continue
				}
				if src[i] == '\n' {
					b.WriteByte('\n')
				} else {
					b.WriteByte(' ')
				}
				i++
			}
			if i < len(src) {
				b.WriteByte(' ')
				i++
			}
			continue
		}

		// Line comment: // ... \n
		if c == '/' && i+1 < len(src) && src[i+1] == '/' {
			for i < len(src) && src[i] != '\n' {
				b.WriteByte(' ')
				i++
			}
			continue
		}

		// Block comment: /* ... */ (with /// doc-comments handled above).
		if c == '/' && i+1 < len(src) && src[i+1] == '*' {
			b.WriteByte(' ')
			b.WriteByte(' ')
			i += 2
			for i+1 < len(src) && !(src[i] == '*' && src[i+1] == '/') {
				if src[i] == '\n' {
					b.WriteByte('\n')
				} else {
					b.WriteByte(' ')
				}
				i++
			}
			if i+1 < len(src) {
				b.WriteByte(' ')
				b.WriteByte(' ')
				i += 2
			}
			continue
		}

		b.WriteByte(c)
		i++
	}
	return b.String()
}

// isIdentChar reports whether b is a Dart identifier continuation char
// (letter, digit, or underscore). Used by the string-scanner to decide
// whether a preceding `r` is the raw-string prefix or just the tail of
// an identifier like `filter('...')`.
func isIdentChar(b byte) bool {
	return (b >= 'a' && b <= 'z') ||
		(b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9') ||
		b == '_' || b == '$'
}

// annotationRe matches Dart annotation tokens at top level (after comment/
// string stripping). Captures the (possibly dotted) annotation name; the
// optional generic-argument and parenthesised-arg suffixes are matched but
// not captured.
var annotationRe = regexp.MustCompile(`@([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)`)

// ParseDartAnnotations returns the names of every annotation used in the
// file at path, in source order. Inside-comment and inside-string occurrences
// are filtered out. Repeats are preserved (so callers can see "@override" twice
// if it really appears twice).
func ParseDartAnnotations(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	stripped := stripCommentsAndStrings(string(data))
	matches := annotationRe.FindAllStringSubmatch(stripped, -1)
	if matches == nil {
		return nil, nil
	}
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out, nil
}

// builtInterfaceRe detects idiomatic built_value classes, which carry no
// annotation: the codegen trigger is an `implements`/`with` clause naming
// `Built<T, TBuilder>` (two type arguments). Applied to comment/string-
// stripped source; `[^{;]*` lets the clause span newlines but stops at the
// class body so `BuiltList<...>` fields can't false-positive. `\b` rejects
// identifiers that merely end in "Built" (e.g. `RebuiltThing`, `NotBuilt`).
var builtInterfaceRe = regexp.MustCompile(
	`(?:implements|with)[^{;]*\bBuilt\s*<\s*[A-Za-z_$][A-Za-z0-9_$]*\s*,\s*[A-Za-z_$][A-Za-z0-9_$]*\s*>`)

// ParseDartCodegenTriggers returns every codegen trigger in the file at
// path: all annotations (as ParseDartAnnotations) plus a synthetic
// "BuiltValue" entry when the source implements `Built<T, B>` — idiomatic
// built_value classes are annotation-free. The synthetic entry is only
// appended when "BuiltValue" isn't already present as a real annotation.
func ParseDartCodegenTriggers(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	stripped := stripCommentsAndStrings(string(data))
	var out []string
	for _, m := range annotationRe.FindAllStringSubmatch(stripped, -1) {
		out = append(out, m[1])
	}
	if builtInterfaceRe.MatchString(stripped) {
		seen := false
		for _, a := range out {
			if a == "BuiltValue" {
				seen = true
				break
			}
		}
		if !seen {
			out = append(out, "BuiltValue")
		}
	}
	return out, nil
}

// partRe matches `part '<uri>';` directives (NOT `part of`). The
// negative-lookahead-style filtering for `part of` is done at scan time.
var partRe = regexp.MustCompile(`^\s*part\s+['"]([^'"]+)['"]\s*;`)
var partOfRe = regexp.MustCompile(`^\s*part\s+of\b`)

// ParseDartParts returns the URIs from every `part '...';` directive in the
// file at path. `part of '...';` directives are explicitly excluded.
func ParseDartParts(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// String literals must be preserved here (the URI is *inside* the
	// quotes), so we strip comments only — not strings.
	stripped := stripCommentsOnly(string(data))
	var parts []string
	for _, line := range strings.Split(stripped, "\n") {
		if partOfRe.MatchString(line) {
			continue
		}
		if m := partRe.FindStringSubmatch(line); m != nil {
			parts = append(parts, m[1])
		}
	}
	return parts, nil
}

// stripCommentsOnly is a lighter version of stripCommentsAndStrings that
// removes line and block comments but leaves string literals intact. Used
// when the contents of strings (e.g. URIs in part directives) carry meaning.
func stripCommentsOnly(src string) string {
	var b strings.Builder
	b.Grow(len(src))

	i := 0
	for i < len(src) {
		// Skip over strings without modifying them.
		if c := src[i]; c == '"' || c == '\'' {
			// Triple-quoted?
			if i+2 < len(src) && src[i+1] == c && src[i+2] == c {
				quote := c
				b.WriteByte(c)
				b.WriteByte(c)
				b.WriteByte(c)
				i += 3
				for i+2 < len(src) && !(src[i] == quote && src[i+1] == quote && src[i+2] == quote) {
					b.WriteByte(src[i])
					i++
				}
				if i+2 < len(src) {
					b.WriteByte(quote)
					b.WriteByte(quote)
					b.WriteByte(quote)
					i += 3
				}
				continue
			}
			quote := c
			b.WriteByte(quote)
			i++
			// Same identifier-boundary guard as stripCommentsAndStrings:
			// a raw-string prefix is a *standalone* `r`, not the tail of
			// an identifier that happens to precede a quote.
			isRaw := i >= 2 && src[i-2] == 'r' &&
				(i < 3 || !isIdentChar(src[i-3]))
			for i < len(src) && src[i] != quote {
				if src[i] == '\\' && !isRaw && i+1 < len(src) {
					b.WriteByte(src[i])
					b.WriteByte(src[i+1])
					i += 2
					continue
				}
				b.WriteByte(src[i])
				i++
			}
			if i < len(src) {
				b.WriteByte(quote)
				i++
			}
			continue
		}

		// Line comment.
		if src[i] == '/' && i+1 < len(src) && src[i+1] == '/' {
			for i < len(src) && src[i] != '\n' {
				b.WriteByte(' ')
				i++
			}
			continue
		}

		// Block comment.
		if src[i] == '/' && i+1 < len(src) && src[i+1] == '*' {
			b.WriteByte(' ')
			b.WriteByte(' ')
			i += 2
			for i+1 < len(src) && !(src[i] == '*' && src[i+1] == '/') {
				if src[i] == '\n' {
					b.WriteByte('\n')
				} else {
					b.WriteByte(' ')
				}
				i++
			}
			if i+1 < len(src) {
				b.WriteByte(' ')
				b.WriteByte(' ')
				i += 2
			}
			continue
		}

		b.WriteByte(src[i])
		i++
	}
	return b.String()
}
