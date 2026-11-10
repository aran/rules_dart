package dart

import (
	"reflect"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/rule"
)

const (
	wcVM    = "@rules_dart//dart/constraints:vm"
	wcJS    = "@rules_dart//dart/constraints:js"
	wcWasm  = "@rules_dart//dart/constraints:wasm"
	osLinux = "@platforms//os:linux"
	osMac   = "@platforms//os:macos"
	osWin   = "@platforms//os:windows"
	dflt    = "//conditions:default"
)

func TestTestOnCompatibility(t *testing.T) {
	for _, tt := range []struct {
		selector string
		want     interface{}
	}{
		{"vm", []string{wcVM}},
		{"dart-vm", []string{wcVM}},
		{"vm || browser", nil},
		{"vm && browser", []string{incompatible}},
		{"browser", rule.SelectStringListValue{wcVM: {incompatible}, dflt: {}}},
		{"js || wasm", rule.SelectStringListValue{wcVM: {incompatible}, dflt: {}}},
		{"!vm", rule.SelectStringListValue{wcVM: {incompatible}, dflt: {}}},
		{"!browser", []string{wcVM}},
		{"js", []string{wcJS}},
		{"wasm", []string{wcWasm}},
		{"linux", []string{osLinux}},
		{"vm && linux", []string{osLinux}},
		{"mac-os", []string{osMac}},
		{"windows", []string{osWin}},
		// A browser has no OS, so `!windows` holds on the web platforms.
		{"!windows", rule.SelectStringListValue{osWin: {incompatible}, dflt: {}}},
		{"vm && !windows", rule.SelectStringListValue{osWin: {incompatible}, dflt: {wcVM}}},
		{"posix", rule.SelectStringListValue{osLinux: {}, osMac: {}, dflt: {incompatible}}},
	} {
		got, err := testOnCompatibility("@TestOn('" + tt.selector + "')\nlibrary;\n")
		if err != nil {
			t.Errorf("%q: %v", tt.selector, err)
			continue
		}
		if !reflect.DeepEqual(got, tt.want) {
			t.Errorf("%q: %#v, want %#v", tt.selector, got, tt.want)
		}
	}
}

func TestTestOnConditional(t *testing.T) {
	got, err := testOnCompatibility("@TestOn('mac-os ? vm : linux')\nimport 'package:test/test.dart';\n")
	if err != nil {
		t.Fatal(err)
	}
	want := rule.SelectStringListValue{osLinux: {}, osMac: {}, dflt: {incompatible}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%#v, want %#v", got, want)
	}
}

func TestTestOnAbsentOrMisplaced(t *testing.T) {
	for _, src := range []string{
		"import 'package:test/test.dart';\n",
		"void main() {}\n@TestOn('vm')\nvoid f() {}\n",
		"// @TestOn('vm')\nlibrary;\n",
	} {
		got, err := testOnCompatibility(src)
		if err != nil || got != nil {
			t.Errorf("%q: %#v, %v; want nothing", src, got, err)
		}
	}
}

func TestTestOnRefused(t *testing.T) {
	for src, want := range map[string]string{
		"@TestOn('chrome')\nlibrary;\n":                 "not \"chrome\"",
		"@TestOn('vm && dart2js')\nlibrary;\n":          "not \"dart2js\"",
		"@TestOn(platform)\nlibrary;\n":                 "not one string literal",
		"@TestOn('vm')\n@TestOn('linux')\nlibrary;\n":   "more than one",
		"@TestOn('vm &&')\nlibrary;\n":                  "expected a variable",
		"@TestOn('(vm || js) && !windows')\nlibrary;\n": "no `target_compatible_with`",
		// The VM on Linux and every web platform, but not the VM on an OS
		// package:test does not know, which has no OS either.
		"@TestOn('linux ? vm : browser')\nlibrary;\n": "no `target_compatible_with`",
	} {
		_, err := testOnCompatibility(src)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: error %v, want one containing %q", src, err, want)
		}
	}
}
