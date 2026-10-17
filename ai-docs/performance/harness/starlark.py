import gzip, json, sys, collections
ev = json.load(gzip.open(sys.argv[1]))["traceEvents"]
c = collections.Counter(); n = collections.Counter()
for e in ev:
    if e.get("ph") == "X" and e.get("cat") == "Starlark user function call":
        c[e["name"]] += e["dur"] / 1e6; n[e["name"]] += 1
for k in sys.argv[2:]: print("%-28s n=%3d total=%.2fs" % (k, n[k], c[k]))
