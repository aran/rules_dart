"""Unit tests for dart/pub/pub_graph.bzl: the graph walk, cycle planning and its declarations."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pub_graph.bzl", "cycle_declaration", "cycle_declarations_error", "cycle_error", "dependency_cycle", "dependency_graph")
load(":small_suite.bzl", "small_unittest_suite")

def _acyclic_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b", "c"], "b": ["c"], "c": []}
    asserts.equals(env, ["a"], dependency_cycle(graph, "a").packages)
    asserts.equals(env, ["c"], dependency_cycle(graph, "c").packages)
    return unittest.end(env)

def _two_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    # dio <-> dio_web_adapter, both on meta, and http on dio.
    graph = {
        "dio": ["dio_web_adapter", "meta"],
        "dio_web_adapter": ["dio", "meta"],
        "meta": [],
        "http": ["dio"],
    }
    declared = [["dio_web_adapter", "dio"]]
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio", declared).packages)
    asserts.equals(env, ["dio", "dio_web_adapter"], dependency_cycle(graph, "dio_web_adapter", declared).packages)
    asserts.equals(env, ["http"], dependency_cycle(graph, "http", declared).packages)
    asserts.equals(env, ["meta"], dependency_cycle(graph, "meta", declared).packages)
    return unittest.end(env)

def _long_cycle_with_tail_test_impl(ctx):
    env = unittest.begin(ctx)
    graph = {"a": ["b"], "b": ["c"], "c": ["a", "d"], "d": ["e"], "e": ["d"]}
    declared = [["a", "b", "c"], ["d", "e"]]
    asserts.equals(env, ["a", "b", "c"], dependency_cycle(graph, "b", declared).packages)
    asserts.equals(env, ["d", "e"], dependency_cycle(graph, "e", declared).packages)
    return unittest.end(env)

def _self_and_unknown_edges_test_impl(ctx):
    env = unittest.begin(ctx)

    # An edge to a name outside the graph (a package declared elsewhere) is a
    # dead end, and a package naming itself is no cycle of several.
    graph = {"a": ["a", "elsewhere"]}
    cycle = dependency_cycle(graph, "a")
    asserts.equals(env, ["a"], cycle.packages)
    asserts.equals(env, ["elsewhere"], cycle.deps)
    return unittest.end(env)

def _owner_and_deps_test_impl(ctx):
    env = unittest.begin(ctx)

    # The cycle's first package by name builds it, and the cycle depends on
    # the union of what its packages depend on outside it, edges to packages
    # absent from the graph included.
    graph = {
        "dio_web_adapter": ["dio", "web", "meta"],
        "dio": ["dio_web_adapter", "meta", "elsewhere"],
        "meta": [],
        "web": [],
    }
    cycle = dependency_cycle(graph, "dio_web_adapter", advisory = [["dio", "dio_web_adapter"]])
    asserts.equals(env, "dio", cycle.owner)
    asserts.equals(env, ["elsewhere", "meta", "web"], cycle.deps)
    asserts.equals(env, [], dependency_cycle(graph, "meta").deps)
    return unittest.end(env)

def _graph_walk_test_impl(ctx):
    env = unittest.begin(ctx)
    edges = {
        "a": ["b", "declared"],
        "b": ["a", "c"],
        "c": [],
        "declared": ["unreached"],
        "unrelated": ["a"],
    }
    asked = []

    def dependencies(p):
        asked.append(p)
        return edges[p]

    # Followed packages are read once each; a package outside `follow` is a
    # leaf whose dependencies are never asked for; nothing unreached is read.
    graph = dependency_graph("a", dependencies, follow = {"a": True, "b": True, "c": True, "unrelated": True})
    asserts.equals(env, {"a": ["b", "declared"], "b": ["a", "c"], "c": []}, graph)
    asserts.equals(env, ["a", "b", "c"], sorted(asked))
    return unittest.end(env)

_DIO = {
    "dio": ["dio_web_adapter", "meta"],
    "dio_web_adapter": ["dio", "meta"],
    "meta": [],
}

def _undeclared_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    # An undeclared cycle names every package in it, a path through them, and the
    # declaration that builds it, in the caller's own tag.
    error = cycle_error(_DIO, "dio_web_adapter", declare = "flutter_pub.cycle")
    asserts.true(env, "Pub packages `dio` and `dio_web_adapter` depend on each other" in error, error)
    asserts.true(env, "dio_web_adapter -> dio -> dio_web_adapter" in error, error)
    asserts.true(env, 'flutter_pub.cycle(packages = ["dio", "dio_web_adapter"])' in error, error)

    # Three packages, in a list a reader can follow.
    graph = {"a": ["b"], "b": ["c"], "c": ["a"]}
    error = cycle_error(graph, "a")
    asserts.true(env, "`a`, `b` and `c` depend on each other: a -> b -> c -> a" in error, error)
    asserts.true(env, 'pub.cycle(packages = ["a", "b", "c"])' in error, error)

    # A package in no cycle needs no declaration.
    asserts.equals(env, None, cycle_error(_DIO, "meta"))
    return unittest.end(env)

def _root_declaration_test_impl(ctx):
    env = unittest.begin(ctx)

    # Exactly the cycle, in any order: planned.
    asserts.equals(env, None, cycle_error(_DIO, "dio", declared = [["dio_web_adapter", "dio"]]))

    # Packages that are no cycle (the edge back went in a newer release): a
    # stale declaration fails rather than lingering.
    acyclic = {"dio": ["dio_web_adapter"], "dio_web_adapter": []}
    error = cycle_error(acyclic, "dio", declared = [["dio", "dio_web_adapter"]])
    asserts.true(env, "`dio` is in no cycle. Remove it from the declaration, or remove the declaration." in error, error)
    asserts.true(env, 'pub.cycle(packages = ["dio", "dio_web_adapter"]), in the root module' in error, error)

    # Part of a cycle fails, giving the whole cycle to declare.
    graph = {"a": ["b"], "b": ["c"], "c": ["a"]}
    error = cycle_error(graph, "b", declared = [["a", "b"]])
    asserts.true(env, "`b` is in the cycle of `a`, `b` and `c` (b -> c -> a -> b)" in error, error)
    asserts.true(env, 'pub.cycle(packages = ["a", "b", "c"])' in error, error)

    # The root's declaration is checked even where an advisory one matches.
    error = cycle_error(_DIO, "dio", declared = [["dio", "dio_web_adapter", "meta"]], advisory = [["dio", "dio_web_adapter"]])
    asserts.true(env, "`dio` is in the cycle of `dio` and `dio_web_adapter`" in error, error)
    return unittest.end(env)

def _advisory_declaration_test_impl(ctx):
    env = unittest.begin(ctx)

    # An advisory declaration (another module's, or curated) builds the cycle
    # it states exactly...
    asserts.equals(env, None, cycle_error(_DIO, "dio", advisory = [["dio", "dio_web_adapter"]]))

    # ...and is inert where it is no cycle, or not all of one.
    acyclic = {"dio": ["dio_web_adapter"], "dio_web_adapter": []}
    asserts.equals(env, None, cycle_error(acyclic, "dio", advisory = [["dio", "dio_web_adapter"]]))
    graph = {"a": ["b"], "b": ["c"], "c": ["a"]}
    error = cycle_error(graph, "a", advisory = [["a", "b"]])
    asserts.true(env, 'pub.cycle(packages = ["a", "b", "c"])' in error, error)
    return unittest.end(env)

def _declarations_form_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 'pub.cycle(packages = ["a", "b"])', cycle_declaration(["b", "a"]))
    asserts.equals(env, None, cycle_declarations_error([["a", "b"], ["c", "d"]], "the root module"))

    error = cycle_declarations_error([["a"]], "the root module")
    asserts.true(env, 'pub.cycle(packages = ["a"]) names fewer than two packages' in error, error)
    error = cycle_declarations_error([["a", "a"]], "module `m`")
    asserts.true(env, "declared by module `m`" in error, error)
    asserts.true(env, "names a package more than once" in error, error)

    # A package in two declarations of one module: one cycle, declared once.
    error = cycle_declarations_error([["a", "b"], ["b", "c"]], "the root module", "flutter_pub.cycle")
    asserts.true(env, '`b` is in both flutter_pub.cycle(packages = ["a", "b"]) and flutter_pub.cycle(packages = ["b", "c"])' in error, error)
    return unittest.end(env)

def _served_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    # A cycle through a package a target of the user's builds is refused
    # whatever is declared, naming that package and the move that builds it.
    graph = {"theirs": ["mine", "meta"], "mine": ["theirs"], "meta": []}
    served = {"mine": "@@//mine:mine"}
    for declared, advisory in [([], []), ([["mine", "theirs"]], []), ([], [["mine", "theirs"]])]:
        error = cycle_error(graph, "theirs", declared = declared, advisory = advisory, served = served)
        asserts.true(env, error != None, "a cycle through a served package must be refused")
        _mentions(env, error, [
            "Packages `mine` and `theirs` depend on each other: theirs -> mine -> theirs.",
            "`mine` is built by @@//mine:mine, a target of yours that `resolve` maps it to.",
            "move it from `resolve` to `build_from_pubspec`",
            'pub.cycle(packages = ["mine", "theirs"])',
            "A `BUILD` file under its `lib/` or `hook/` has to go",
        ])

    # Two served packages are both named.
    ring = {"a": ["b"], "b": ["c"], "c": ["a"]}
    error = cycle_error(ring, "a", served = {"b": "@@//b:b", "c": "@@//c:c"})
    _mentions(env, error, [
        "`b` and `c` are built by targets of yours that `resolve` maps them to (@@//b:b, @@//c:c).",
        "move them from `resolve`",
        "under their `lib/`",
    ])

    # A served package in no cycle, or one beside the cycle, plans as before.
    asserts.equals(env, None, cycle_error(graph, "meta", served = served))
    asserts.equals(env, None, cycle_error({"a": ["mine"], "mine": []}, "a", served = served))
    error = cycle_error({"a": ["b", "mine"], "b": ["a"], "mine": []}, "a", served = served)
    asserts.true(env, "Pub packages `a` and `b` depend on each other" in error, error)
    cycle = dependency_cycle({"a": ["b", "mine"], "b": ["a"], "mine": []}, "a", declared = [["a", "b"]], served = served)
    asserts.equals(env, ["mine"], cycle.deps)
    return unittest.end(env)

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "expected {} in:\n{}".format(repr(fragment), text))

_t0_test = unittest.make(_acyclic_test_impl)
_t1_test = unittest.make(_two_cycle_test_impl)
_t2_test = unittest.make(_long_cycle_with_tail_test_impl)
_t3_test = unittest.make(_self_and_unknown_edges_test_impl)
_t4_test = unittest.make(_owner_and_deps_test_impl)
_t5_test = unittest.make(_graph_walk_test_impl)
_t6_test = unittest.make(_undeclared_cycle_test_impl)
_t7_test = unittest.make(_root_declaration_test_impl)
_t8_test = unittest.make(_advisory_declaration_test_impl)
_t9_test = unittest.make(_declarations_form_test_impl)
_t10_test = unittest.make(_served_cycle_test_impl)

def pub_graph_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test)
