import random
src = open("../tb/golden.txt").read().split("\n")
vecs = []
for l in src:
    p = l.split()
    if len(p) == 6:
        vecs.append(tuple(int(x,16) if i in (1,2,4,5) else int(x) for i,x in enumerate(p)))
random.seed(42)
sel = vecs[:200] + random.sample(vecs[200:], 1800)
with open("stim_small.hex","w") as f1, open("exp_small.hex","w") as f2:
    for fmt, a, b, rm, res, fl in sel:
        f1.write("%018x\n" % ((fmt << 67) | (a << 35) | (b << 3) | rm))
        f2.write("%020x\n" % ((res << 16) | fl))
random.seed(42)
sel2 = vecs[:200] + random.sample(vecs[200:], 100000)
with open("stim.hex","w") as f1, open("exp.hex","w") as f2:
    for fmt, a, b, rm, res, fl in sel2:
        f1.write("%018x\n" % ((fmt << 67) | (a << 35) | (b << 3) | rm))
        f2.write("%020x\n" % ((res << 16) | fl))
print("regenerated both sets")
