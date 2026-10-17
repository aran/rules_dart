import gzip, json, sys, collections
d = json.load(gzip.open(sys.argv[1]))
ev = d["traceEvents"] if isinstance(d, dict) else d
threads = {}
for e in ev:
    if e.get("ph") == "M" and e.get("name") == "thread_name":
        threads[e["tid"]] = e["args"]["name"]
phases = []
by_mn = collections.defaultdict(list)
cats = collections.Counter()
for e in ev:
    if e.get("ph") != "X": continue
    c = e.get("cat", "")
    if c == "build phase marker" : phases.append((e["name"], e["ts"]))
    if c == "action processing":
        mn = e.get("args", {}).get("mnemonic") or e["name"].split(" ")[0]
        by_mn[mn].append(e["dur"] / 1e6)
    cats[c] += e.get("dur", 0) / 1e6
for e in ev:
    if e.get("cat") == "build phase marker": print("phase", e["name"], e["ts"]/1e6)
print("%-28s %5s %9s %8s %8s" % ("mnemonic", "n", "total_s", "mean_s", "max_s"))
for mn, ds in sorted(by_mn.items(), key=lambda kv: -sum(kv[1])):
    print("%-28s %5d %9.2f %8.2f %8.2f" % (mn, len(ds), sum(ds), sum(ds)/len(ds), max(ds)))
if len(sys.argv) > 2:
    print("\ncategories (summed durations):")
    for c, t in cats.most_common(25): print("  %-40s %9.2f" % (c, t))
