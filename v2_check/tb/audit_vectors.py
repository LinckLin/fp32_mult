import re

def ref(a, b, rm):
    rs = (a ^ b) & 0x80000000
    aE = (a >> 23) & 0xFF; bE = (b >> 23) & 0xFF
    aF = a & 0x7FFFFF; bF = b & 0x7FFFFF
    aZ = aE == 0 and aF == 0; bZ = bE == 0 and bF == 0
    aI = aE == 0xFF and aF == 0; bI = bE == 0xFF and bF == 0
    aN = aE == 0xFF and aF != 0; bN = bE == 0xFF and bF != 0
    aSn = aN and not (aF & 0x400000); bSn = bN and not (bF & 0x400000)
    fl = 0x10 if (aSn or bSn) else 0
    if aN or bN:
        return (rs | 0x7F800000 | 0x400000 | (aF if aN else bF), fl)
    if (aZ and bI) or (bZ and aI):
        return (rs | 0x7FC00000, fl | 0x10)
    if aI or bI:
        return (rs | 0x7F800000, 0)
    if aZ or bZ:
        return (rs, 0)
    sa = (0x800000 | aF) if aE else aF
    sb = (0x800000 | bF) if bE else bF
    ea = aE if aE else 1
    eb = bE if bE else 1
    p = sa * sb
    lz = 0
    for i in range(47, -1, -1):
        if (p >> i) & 1:
            lz = 47 - i
            break
    E = ea + eb - 127 + 1 - lz
    sh = p << lz
    m = (sh >> 24) & 0xFFFFFF
    G = (sh >> 23) & 1
    R = (sh >> 22) & 1
    S = 1 if (sh & ((1 << 22) - 1)) else 0
    sgn = 1 if rs else 0
    def inc(g, r, s, lsb):
        if rm == 0: return g & (r | s | lsb)
        if rm == 4: return g
        if rm == 1: return 0
        if rm == 2: return sgn & (g | r | s)
        if rm == 3: return (1 - sgn) & (g | r | s)
        return g & (r | s | lsb)
    if E <= 0:
        k = 25 - E
        field = 0 if k >= 48 else (sh >> k) & 0x7FFFFF
        G2 = ((sh >> (k - 1)) & 1) if k <= 48 else 0
        R2 = ((sh >> (k - 2)) & 1) if k <= 49 else 0
        S2 = ((sh & ((1 << (k - 2)) - 1)) != 0) if k <= 50 else True
        inex = G2 | R2 | S2
        f = field + inc(G2, R2, S2, field & 1)
        if f == 0x800000:
            return (rs | 0x00800000, (0x1 | 0x2) if inex else 0)
        return (rs | f, (0x1 | 0x2) if inex else 0)
    mr = m + inc(G, R, S, m & 1)
    Ef = E + (mr >> 24)
    inex = G | R | S
    if Ef >= 255:
        if rm == 1: v = rs | 0x7F7FFFFF
        elif rm == 2: v = 0xFF800000 if sgn else 0x7F7FFFFF
        elif rm == 3: v = 0xFF7FFFFF if sgn else 0x7F800000
        else: v = rs | 0x7F800000
        return (v, 0x1 | 0x4)
    mm = 0x800000 if (mr >> 24) else mr
    return (rs | (Ef << 23) | (mm & 0x7FFFFF), 0x1 if inex else 0)

src = open('tb/fp32_mult_tb.cpp').read()
i = src.find('kDirected[] = {')
j = src.find('};', i)
body = src[i:j]
body = body.replace('FL_NV | FL_UF', '0x12').replace('FL_OF | FL_NX', '0x05')
body = body.replace('FL_NX | FL_UF', '0x03').replace('FL_NV', '0x10').replace('FL_NX', '0x01')
pat = re.compile(r'\{0x([0-9A-Fa-f]+)u, 0x([0-9A-Fa-f]+)u, (\d), 0x([0-9A-Fa-f]+)u, (0x[0-9A-Fa-f]+|\d+), *"(.*?)"\},?')
bad = 0
n = 0
for mm in pat.finditer(body):
    n += 1
    a = int(mm.group(1), 16); b = int(mm.group(2), 16); rm = int(mm.group(3))
    ev = int(mm.group(4), 16); ef = int(mm.group(5), 16)
    got = ref(a, b, rm)
    if (got[0], got[1]) != (ev, ef):
        bad += 1
        print('id %d: %r  table=(%#010x,%#04x)  correct=(%#010x,%#04x)'
              % (n - 1, mm.group(6), ev, ef, got[0], got[1]))
print('checked %d vectors, %d mismatches' % (n, bad))
