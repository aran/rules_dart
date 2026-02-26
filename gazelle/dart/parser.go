package dart

import (
	"bufio"
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

// ParseDartFile extracts import/export URIs from a Dart source file.
func ParseDartFile(path string) ([]DartImport, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var imports []DartImport
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		m := importRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		uri := m[1]
		imp := DartImport{URI: uri}

		if strings.HasPrefix(uri, "dart:") {
			imp.IsDartSDK = true
		} else if strings.HasPrefix(uri, "package:") {
			imp.IsPackage = true
			// package:foo/bar.dart -> package=foo, path=bar.dart
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

		imports = append(imports, imp)
	}
	return imports, scanner.Err()
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
