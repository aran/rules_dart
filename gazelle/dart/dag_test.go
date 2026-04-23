package dart

import (
	"testing"
)

// registryWith builds a minimal registry from a flat list of builderInfo.
// Entries sharing an annotation fan out through the multi-registration
// map (mirroring @StackedApp's five sub-builders against real data).
func registryWith(infos ...*builderInfo) *builderRegistry {
	r := &builderRegistry{byAnnotation: map[string][]*builderInfo{}}
	for _, i := range infos {
		r.byAnnotation[i.Annotation] = append(r.byAnnotation[i.Annotation], i)
	}
	return r
}

func TestBuildPipelineForFile(t *testing.T) {
	jsonInfo := &builderInfo{
		Annotation: "JsonSerializable",
		ShimLabel:  "@json:shim",
		Produces:   []string{".json_serializable.g.part"},
		Consumes:   []string{".dart"},
		SharedPart: true,
	}
	freezedInfo := &builderInfo{
		Annotation: "Freezed",
		ShimLabel:  "@freezed:shim",
		Produces:   []string{".freezed.dart"},
		Consumes:   []string{".dart"},
		RunsBefore: []string{"JsonSerializable"},
	}
	copyInfo := &builderInfo{
		Annotation: "CopyWith",
		ShimLabel:  "@copy:shim",
		Produces:   []string{".copy_with_extension_gen.g.part"},
		Consumes:   []string{".dart"},
		SharedPart: true,
	}

	t.Run("single SharedPart adds combining stage", func(t *testing.T) {
		stages, err := buildPipelineForFile([]string{"JsonSerializable"},
			registryWith(jsonInfo))
		if err != nil {
			t.Fatal(err)
		}
		if len(stages) != 2 {
			t.Fatalf("got %d stages, want 2 (json + combining)", len(stages))
		}
		if stages[0].Combining || stages[0].Builder.Annotation != "JsonSerializable" {
			t.Errorf("stage[0] = %#v", stages[0])
		}
		if !stages[1].Combining || len(stages[1].OutputExts) != 1 ||
			stages[1].OutputExts[0] != ".g.dart" {
			t.Errorf("stage[1] = %#v", stages[1])
		}
		if len(stages[1].PartShards) != 1 {
			t.Errorf("partShards = %v", stages[1].PartShards)
		}
	})

	t.Run("multi SharedPart fans into combining", func(t *testing.T) {
		stages, err := buildPipelineForFile(
			[]string{"JsonSerializable", "CopyWith"},
			registryWith(jsonInfo, copyInfo))
		if err != nil {
			t.Fatal(err)
		}
		if len(stages) != 3 {
			t.Fatalf("got %d stages, want 3", len(stages))
		}
		// Order is alphabetical for parallel-ready stages.
		if stages[0].Builder.Annotation != "CopyWith" {
			t.Errorf("stage[0] = %#v (expected CopyWith first by sort)", stages[0])
		}
		if stages[1].Builder.Annotation != "JsonSerializable" {
			t.Errorf("stage[1] = %#v", stages[1])
		}
		if !stages[2].Combining {
			t.Errorf("stage[2] should be combining, got %#v", stages[2])
		}
		if len(stages[2].PartShards) != 2 {
			t.Errorf("expected 2 part shards, got %v", stages[2].PartShards)
		}
	})

	t.Run("runs_before orders cascade", func(t *testing.T) {
		stages, err := buildPipelineForFile(
			[]string{"JsonSerializable", "Freezed"},
			registryWith(jsonInfo, freezedInfo))
		if err != nil {
			t.Fatal(err)
		}
		if stages[0].Builder.Annotation != "Freezed" {
			t.Errorf("stage[0] = %#v (expected Freezed first)", stages[0])
		}
		if stages[1].Builder.Annotation != "JsonSerializable" {
			t.Errorf("stage[1] = %#v", stages[1])
		}
	})

	t.Run("non-SharedPart needs no combining stage", func(t *testing.T) {
		stages, err := buildPipelineForFile([]string{"Freezed"},
			registryWith(freezedInfo))
		if err != nil {
			t.Fatal(err)
		}
		if len(stages) != 1 {
			t.Fatalf("got %d stages, want 1 (no combining for PartBuilder)", len(stages))
		}
		if stages[0].Combining {
			t.Errorf("stage[0] should not be combining: %#v", stages[0])
		}
	})

	t.Run("cycle errors out", func(t *testing.T) {
		a := &builderInfo{Annotation: "A", ShimLabel: "@a", Produces: []string{".a"},
			Consumes: []string{".dart"}, RunsBefore: []string{"B"}}
		b := &builderInfo{Annotation: "B", ShimLabel: "@b", Produces: []string{".b"},
			Consumes: []string{".dart"}, RunsBefore: []string{"A"}}
		_, err := buildPipelineForFile([]string{"A", "B"}, registryWith(a, b))
		if err == nil {
			t.Fatal("expected cycle error")
		}
	})

	t.Run("unregistered annotation is ignored", func(t *testing.T) {
		stages, err := buildPipelineForFile([]string{"NotRegistered", "Freezed"},
			registryWith(freezedInfo))
		if err != nil {
			t.Fatal(err)
		}
		if len(stages) != 1 || stages[0].Builder.Annotation != "Freezed" {
			t.Fatalf("expected just Freezed, got %#v", stages)
		}
	})

	t.Run("one annotation fans out to multiple builders", func(t *testing.T) {
		routerInfo := &builderInfo{
			Annotation: "StackedApp",
			ShimLabel:  "@stacked:router",
			Produces:   []string{".router.dart"},
			Consumes:   []string{".dart"},
		}
		locatorInfo := &builderInfo{
			Annotation: "StackedApp",
			ShimLabel:  "@stacked:locator",
			Produces:   []string{".locator.dart"},
			Consumes:   []string{".dart"},
		}
		loggerInfo := &builderInfo{
			Annotation: "StackedApp",
			ShimLabel:  "@stacked:logger",
			Produces:   []string{".logger.dart"},
			Consumes:   []string{".dart"},
		}
		stages, err := buildPipelineForFile(
			[]string{"StackedApp"},
			registryWith(routerInfo, locatorInfo, loggerInfo))
		if err != nil {
			t.Fatal(err)
		}
		if len(stages) != 3 {
			t.Fatalf("expected 3 stages (one per stacked sub-builder), got %d",
				len(stages))
		}
		// No combining stage — none are SharedPart.
		for _, s := range stages {
			if s.Combining {
				t.Errorf("unexpected combining stage: %#v", s)
			}
		}
		// Verify all three produced extensions show up; ordering is
		// alphabetical by node key (annotation|ext).
		seen := map[string]bool{}
		for _, s := range stages {
			seen[s.OutputExts[0]] = true
		}
		for _, want := range []string{".router.dart", ".locator.dart", ".logger.dart"} {
			if !seen[want] {
				t.Errorf("missing stage with output %q", want)
			}
		}
	})
}
