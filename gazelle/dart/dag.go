package dart

import (
	"fmt"
	"sort"
)

// pipelineStage represents one rule the DAG-emitter will produce: a
// single dart_codegen / dart_aggregate_codegen / combining_shim
// invocation operating on one input source.
type pipelineStage struct {
	// Builder is the registered builder driving this stage. Nil for the
	// synthetic combining stage.
	Builder *builderInfo
	// Combining is true for the synthetic .g.part → .g.dart merge stage.
	Combining bool
	// OutputExts is the list of extensions this stage emits, in the order
	// declared by the builder's `Produces` (or `[".g.dart"]` for
	// combining). The rule layer sets `output_suffixes=[...]` to this.
	OutputExts []string
	// PartShards lists prior-stage IDs whose `.g.part` outputs this
	// combining stage merges. Empty for non-combining stages.
	PartShards []string
	// ID is the unique node ID of this stage within the pipeline graph.
	// Non-combining stages use `(annotation, primary-produced-ext)` to
	// disambiguate multiple builders that watch the same annotation
	// (e.g. @StackedApp fans out to five). Combining stages use
	// `__combining`.
	ID string
}

// buildPipelineForFile orders every registered builder applicable to the
// file's annotations into a deterministic pipeline of stages, plus a
// combining stage when one or more SharedPart shards are emitted. Returns
// an error on cycles or genuinely-conflicting `runs_before` constraints.
//
// Multiple builders can watch the same annotation (e.g. @StackedApp fans
// out to five sub-builders). Nodes are keyed on `(annotation,
// primary-produced-ext)` so each sub-builder is a distinct node.
func buildPipelineForFile(
	annotations []string,
	registry *builderRegistry,
) ([]pipelineStage, error) {
	var nodes []*builderInfo
	seenAnnotation := map[string]struct{}{}
	for _, a := range annotations {
		if _, ok := seenAnnotation[a]; ok {
			continue
		}
		seenAnnotation[a] = struct{}{}
		for _, info := range registry.lookup(a) {
			nodes = append(nodes, info)
		}
	}
	// Dedupe nodes by (annotation, shim label, primary produced extension).
	seenNode := map[string]struct{}{}
	deduped := nodes[:0]
	for _, n := range nodes {
		key := nodeKey(n)
		if _, ok := seenNode[key]; ok {
			continue
		}
		seenNode[key] = struct{}{}
		deduped = append(deduped, n)
	}
	nodes = deduped

	if len(nodes) == 0 {
		return nil, nil
	}

	// Topological sort. Edges: A → B means A must run before B. Sources
	// of edges:
	//   1. consumes/produces — if A produces ext X and B consumes X, A→B.
	//   2. runs_before — explicit override (refers to annotation names).
	indegree := map[string]int{}
	adj := map[string][]string{}
	byID := map[string]*builderInfo{}
	type edge struct{ from, to string }
	seenEdge := map[edge]bool{}
	for _, n := range nodes {
		id := nodeKey(n)
		byID[id] = n
		indegree[id] = 0
	}

	addEdge := func(fromID, toID string) {
		if _, ok := byID[fromID]; !ok {
			return
		}
		if _, ok := byID[toID]; !ok {
			return
		}
		if fromID == toID {
			return
		}
		e := edge{fromID, toID}
		if seenEdge[e] {
			return
		}
		seenEdge[e] = true
		adj[fromID] = append(adj[fromID], toID)
		indegree[toID]++
	}

	// consumes/produces edges.
	for _, a := range nodes {
		for _, b := range nodes {
			if a == b {
				continue
			}
			for _, p := range a.Produces {
				for _, c := range b.Consumes {
					if p == c {
						addEdge(nodeKey(a), nodeKey(b))
					}
				}
			}
		}
	}

	// runs_before overrides. `runs_before` names annotations; fan out to
	// every node watching that annotation.
	for _, a := range nodes {
		for _, targetAnn := range a.RunsBefore {
			for _, b := range nodes {
				if b.Annotation == targetAnn {
					addEdge(nodeKey(a), nodeKey(b))
				}
			}
		}
	}

	var orderIDs []string
	queue := []string{}
	for _, n := range nodes {
		if indegree[nodeKey(n)] == 0 {
			queue = append(queue, nodeKey(n))
		}
	}
	sort.Strings(queue) // deterministic

	for len(queue) > 0 {
		head := queue[0]
		queue = queue[1:]
		orderIDs = append(orderIDs, head)
		children := append([]string(nil), adj[head]...)
		sort.Strings(children)
		for _, c := range children {
			indegree[c]--
			if indegree[c] == 0 {
				queue = append(queue, c)
			}
		}
	}

	if len(orderIDs) != len(nodes) {
		return nil, fmt.Errorf("cycle detected in dart_builder pipeline for annotations %v", annotations)
	}

	// Build per-builder stages, plus a combining stage if any SharedPart
	// shards were emitted.
	var stages []pipelineStage
	var partShards []string
	for _, id := range orderIDs {
		b := byID[id]
		stages = append(stages, pipelineStage{
			Builder:    b,
			OutputExts: append([]string(nil), b.Produces...),
			ID:         id,
		})
		if b.SharedPart {
			partShards = append(partShards, id)
		}
	}
	if len(partShards) > 0 {
		stages = append(stages, pipelineStage{
			Combining:  true,
			OutputExts: []string{".g.dart"},
			PartShards: partShards,
			ID:         "__combining",
		})
	}
	return stages, nil
}

// nodeKey returns the unique DAG-node ID for a builder: the annotation
// plus the primary produced extension. Two builders watching the same
// annotation (e.g. @StackedApp's five sub-builders) get distinct IDs
// because each produces a different extension.
func nodeKey(b *builderInfo) string {
	primary := ""
	if len(b.Produces) > 0 {
		primary = b.Produces[0]
	}
	return b.Annotation + "|" + primary
}
