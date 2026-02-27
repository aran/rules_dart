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
