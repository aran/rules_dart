# Body-only edit to a leaf file: bumps the constant in m0 of pkgN/f0.
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r"i \* 1 \+ (\d+)\]", lambda m: f"i * 1 + {int(m[1]) + 1}]", s, count=1)
if s2 == s:
    s2 = s.replace("i * 1]", "i * 1 + 0]", 1)
assert s2 != s
open(p, "w").write(s2)
