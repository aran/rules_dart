package dart

import (
	"testing"
)

func TestProducedFiles(t *testing.T) {
	registry := registryWith(
		&builderInfo{Annotation: "X", Produces: []string{".x.g.part"}, SharedPart: true},
		&builderInfo{Annotation: "Y", Produces: []string{".y.dart"}},
	)
	got := producedFiles("pkg/lib/src/user.dart", []string{"X", "Y"}, registry)
	want := []string{"pkg/lib/src/user.g.dart", "pkg/lib/src/user.y.dart"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("produced %v, want %v", got, want)
	}
}

func TestDefaultBuildersIncludesShipped(t *testing.T) {
	r := &builderRegistry{byAnnotation: map[string][]*builderInfo{}}
	for _, b := range defaultBuilders() {
		r.byAnnotation[b.Annotation] = append(r.byAnnotation[b.Annotation], b)
	}
	for _, want := range []string{
		"JsonSerializable", "freezed", "Freezed", "CopyWith",
		"GenerateMocks",
		"DriftDatabase", "StackedApp", "FormView", "SerializersFor",
	} {
		if r.lookup(want) == nil {
			t.Errorf("default registry missing %s", want)
		}
	}
	// @SerializersFor is the annotation-driven entry point to built_value
	// (e.g. serializers.dart in the e2e exemplar); it must map onto the
	// same built_value builder as the synthetic BuiltValue trigger.
	sfor := r.lookup("SerializersFor")
	bval := r.lookup("BuiltValue")
	if len(sfor) != 1 || len(bval) != 1 {
		t.Fatalf("SerializersFor/BuiltValue should each register exactly one builder, got %d/%d", len(sfor), len(bval))
	}
	if sfor[0].ShimLabel != bval[0].ShimLabel || sfor[0].Macro != bval[0].Macro {
		t.Errorf("SerializersFor should share built_value's shim/macro, got %+v", sfor[0])
	}
	// @StackedApp must fan out to exactly five builders (router, locator,
	// logger, dialog, bottomsheet — form uses @FormView separately).
	got := len(r.lookup("StackedApp"))
	if got != 5 {
		t.Errorf("@StackedApp should register 5 sub-builders, got %d", got)
	}
}
