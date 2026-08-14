src = open("../tb/golden.txt").read().split("\n")
n = 0
with open("stim_full.hex","w") as f1, open("exp_full.hex","w") as f2:
    for l in src:
        p = l.split()
        if len(p) != 6: continue
        fmt, a, b, rm, res, fl = int(p[0]), int(p[1],16), int(p[2],16), int(p[3]), int(p[4],16), int(p[5],16)
        f1.write("%018x\n" % ((fmt << 67) | (a << 35) | (b << 3) | rm))
        f2.write("%020x\n" % ((res << 16) | fl))
        n += 1
print("full set:", n)
