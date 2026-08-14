#!/usr/bin/env python3
# ==============================================================================
# gen_golden.py : independent golden-vector generator for fp32_mult
# ==============================================================================
# Implements the IEEE-754 semantics of every supported format in exact integer
# arithmetic and emits "fmt a b rm result flags" lines. The C++ testbench
# replays these vectors against the DUT AND cross-checks its own reference
# model against this file, giving two independent oracles.
#
# Format conventions (see rtl/fp32_defs.vh):
#   FP: sign[31] / exponent[30:31-EW] / fraction[F-1:0], right-aligned
#   INT: value[N-1:0]; result is the 2N-bit product, sign/zero extended to 32
#   E4M3FN: no infinity; NaN = S.1111.111; overflow -> NaN + OF|NX
#   Underflow: tininess before rounding (x86/ARM convention)
# ==============================================================================

import indep_model          # second spec-derived oracle (different algorithm)

FMTS = {
    0:  dict(name='FP32',  ew=8, f=23, bias=127),
    1:  dict(name='FP16',  ew=5, f=10, bias=15),
    2:  dict(name='BF16',  ew=8, f=7,  bias=127),
    3:  dict(name='TF32',  ew=8, f=10, bias=127),
    4:  dict(name='BF32',  ew=8, f=15, bias=127),
    5:  dict(name='E5M2',  ew=5, f=2,  bias=15),
    6:  dict(name='E4M3',  ew=4, f=3,  bias=7, no_inf=True),
    7:  dict(name='E2M1',  ew=2, f=1,  bias=1),
    8:  dict(name='INT4U',  n=4,  signed=False),
    9:  dict(name='INT4S',  n=4,  signed=True),
    10: dict(name='INT8U',  n=8,  signed=False),
    11: dict(name='INT8S',  n=8,  signed=True),
    12: dict(name='INT16U', n=16, signed=False),
    13: dict(name='INT16S', n=16, signed=True),
}

FL_NX, FL_UF, FL_OF, FL_NV = 0x1, 0x2, 0x4, 0x10


def lane_lw(fmt):
    return {14: 16, 15: 16, 16: 8, 17: 8, 18: 4,
            19: 8, 20: 8, 21: 4, 22: 4}[fmt]


def lane_scalar_fmt(fmt):
    return {14: 1, 15: 2, 16: 6, 17: 5, 18: 7,
            19: 10, 20: 11, 21: 8, 22: 9}[fmt]


def ref(fmt, a, b, rm):
    if fmt >= 14:
        lw = lane_lw(fmt)
        n = 2 if fmt in (14, 15) else 4
        sf = lane_scalar_fmt(fmt)
        lmask = (1 << lw) - 1
        d = FMTS[sf]
        is_int = 'n' in d
        if is_int:
            em = fm = 0
        else:
            em = (1 << d['ew']) - 1
            fm = (1 << d['f']) - 1

        def lane_to_scalar(l):
            if is_int:
                return l
            s = (l >> (lw - 1)) & 1
            e = (l >> d['f']) & em
            fr = l & fm
            return (s << 31) | (e << (31 - d['ew'])) | fr

        rw = (2 * lw) if is_int else lw   # per-lane result width

        def scalar_to_lane(r):
            if is_int:
                return r & ((1 << rw) - 1)
            s = (r >> 31) & 1
            e = (r >> (31 - d['ew'])) & em
            fr = r & fm
            return (s << (lw - 1)) | (e << (lw - 1 - d['ew'])) | fr

        res = 0
        fl = 0
        for i in range(n):
            r, f2 = ref(sf, lane_to_scalar((a >> (i * lw)) & lmask),
                        lane_to_scalar((b >> (i * lw)) & lmask), rm)
            res |= scalar_to_lane(r) << (i * rw)
            # 4-bit lane flags {NV, OF, UF, NX} from the 5-bit scalar flags
            fl |= (((f2 & 0x10) >> 1) | (f2 & 0x7)) << (4 * i)
        return res, fl
    d = FMTS[fmt]
    if 'n' in d:
        return ref_int(d, a, b, rm)
    return ref_fp(d, a, b, rm)


def ref_int(d, a, b, rm):
    n = d['n']
    sgn = d['signed']
    mask = (1 << n) - 1
    ma = a & mask
    mb = b & mask
    if sgn:
        if (ma >> (n - 1)) & 1:
            ma = ((~ma) + 1) & mask
        if (mb >> (n - 1)) & 1:
            mb = ((~mb) + 1) & mask
    p = ma * mb
    r = p & ((1 << (2 * n)) - 1)
    if sgn:
        if (r >> (2 * n - 1)) & 1:
            r |= 0xFFFFFFFF & ~((1 << (2 * n)) - 1)
        if (((a >> (n - 1)) ^ (b >> (n - 1))) & 1):
            r = (0 - r) & 0xFFFFFFFF
    return r & 0xFFFFFFFF, 0


def ref_fp(d, a, b, rm):
    ew, f, bias = d['ew'], d['f'], d['bias']
    no_inf = d.get('no_inf', False)
    em = (1 << ew) - 1
    fm = (1 << f) - 1
    exp_all_pat = em << (31 - ew)
    qbit = 1 << (f - 1)

    def dec(x):
        e = (x >> (31 - ew)) & em
        fr = x & fm
        return (x >> 31) & 1, e, fr

    sa, ea, fa = dec(a)
    sb, eb, fb = dec(b)
    rs = sa ^ sb

    aN = (ea == em and fa == fm) if no_inf else (ea == em and fa != 0)
    bN = (eb == em and fb == fm) if no_inf else (eb == em and fb != 0)
    aI = False if no_inf else (ea == em and fa == 0)
    bI = False if no_inf else (eb == em and fb == 0)
    aZ = ea == 0 and fa == 0
    bZ = eb == 0 and fb == 0
    aSn = aN and not ((fa >> (f - 1)) & 1)
    bSn = bN and not ((fb >> (f - 1)) & 1)
    fl = FL_NV if (aSn or bSn) else 0

    if aN or bN:
        pl = fa if aN else fb
        return (rs << 31) | exp_all_pat | qbit | (pl & (qbit - 1)), fl
    if (aZ and bI) or (bZ and aI):
        extra = (qbit - 1) if no_inf else 0
        return (rs << 31) | exp_all_pat | qbit | extra, fl | FL_NV
    if aI or bI:
        return (rs << 31) | exp_all_pat, 0
    if aZ or bZ:
        return rs << 31, 0

    siga = (1 << f) | fa if ea else fa
    sigb = (1 << f) | fb if eb else fb
    eua = ea if ea else 1
    eub = eb if eb else 1
    p = siga * sigb
    lz = 48 - p.bit_length()
    pn = p << lz
    pa = pn >> (23 - f)
    E = eua + eub - bias
    E3 = E + (47 - 2 * f) - lz
    m = (pa >> 24) & ((1 << (f + 1)) - 1)
    G = (pa >> 23) & 1
    R = (pa >> 22) & 1
    S = 1 if (pa & ((1 << 22) - 1)) else 0

    def inc(g, r, s, lsb):
        if rm == 0:
            return g & (r | s | lsb)
        if rm == 4:
            return g
        if rm == 1:
            return 0
        if rm == 2:
            return rs & (g | r | s)
        if rm == 3:
            return (1 - rs) & (g | r | s)
        return g & (r | s | lsb)

    if E3 <= 0:
        k = 25 - E3
        field = 0 if k >= 48 else (pa >> k) & fm
        G2 = ((pa >> (k - 1)) & 1) if k <= 48 else 0
        R2 = ((pa >> (k - 2)) & 1) if k <= 49 else 0
        S2 = ((pa & ((1 << (k - 2)) - 1)) != 0) if k <= 50 else True
        inex = G2 | R2 | S2
        fld = field + inc(G2, R2, S2, field & 1)
        if fld == (1 << f):
            return (rs << 31) | (1 << (31 - ew)), (FL_NX | FL_UF) if inex else 0
        return (rs << 31) | fld, (FL_NX | FL_UF) if inex else 0

    mr = m + inc(G, R, S, m & 1)
    carry = (mr >> (f + 1)) & 1
    Ef = E3 + carry
    inex = G | R | S
    frac = 0 if carry else (mr & fm)
    # E4M3FN keeps exp field 2^EW-1 finite (256..448): overflow only when
    # Ef > 2^EW-1, or Ef == 2^EW-1 with an all-ones rounded mantissa (480).
    if Ef > em or (Ef == em and (not no_inf or frac == fm)):
        if no_inf:
            return (rs << 31) | exp_all_pat | fm, FL_NX | FL_OF
        max_pat = (rs << 31) | ((em - 1) << (31 - ew)) | fm
        inf_pat = (rs << 31) | exp_all_pat
        if rm == 1:
            v = max_pat
        elif rm == 2:
            v = inf_pat if rs else max_pat
        elif rm == 3:
            v = max_pat if rs else inf_pat
        else:
            v = inf_pat
        return v, FL_NX | FL_OF
    return (rs << 31) | (Ef << (31 - ew)) | frac, FL_NX if inex else 0


def fp_specials(fmt):
    d = FMTS[fmt]
    ew, f, bias = d['ew'], d['f'], d['bias']
    em = (1 << ew) - 1
    fm = (1 << f) - 1

    def enc(s, e, fr):
        return (s << 31) | (e << (31 - ew)) | fr

    pats = [enc(0, 0, 0), enc(1, 0, 0),            # +-0
            enc(0, 0, 1), enc(1, 0, 1),            # +-min subnormal
            enc(0, 0, fm), enc(1, 0, fm),          # +-max subnormal
            enc(0, 1, 0), enc(1, 1, 0),            # +-min normal
            enc(0, bias, 0), enc(1, bias, 0),      # +-1.0
            enc(0, bias, 1), enc(1, bias, 1),      # +-(1+2^-F)
            enc(0, bias + 1, 0), enc(1, bias + 1, 0),  # +-2.0
            enc(0, em - 1, fm), enc(1, em - 1, fm)]     # +-max finite
    if d.get('no_inf', False):
        pats += [enc(0, em, fm), enc(1, em, fm)]   # E4M3: the single NaN
    else:
        pats += [enc(0, em, 0), enc(1, em, 0),     # +-inf
                 enc(0, em, fm), enc(1, em, fm),   # +-qNaN
                 enc(0, em, 1), enc(1, em, 1)]     # +-sNaN (quiet bit 0)
        if f == 2:                                 # E5M2: also NaN payload 10
            pats += [enc(0, em, 2), enc(1, em, 2)]
        if f == 1:                                 # E2M1: single NaN only
            pats = pats[:-2]
    return pats


def fp_boundaries(fmt):
    d = FMTS[fmt]
    ew, f, bias = d['ew'], d['f'], d['bias']
    em = (1 << ew) - 1
    fm = (1 << f) - 1

    def enc(s, e, fr):
        return (s << 31) | (e << (31 - ew)) | fr

    half = enc(0, bias - 1, 0)          # 0.5
    one_eps = enc(0, bias, 1)           # 1 + 2^-F
    one_half = enc(0, bias, fm >> 1)    # 1.5
    min_sub = enc(0, 0, 1)
    max_sub = enc(0, 0, fm)
    min_norm = enc(0, 1, 0)
    maxf = enc(0, em - 1, fm)
    two = enc(0, bias + 1, 0)
    pwr = enc(0, em - 2, 0)             # 2^(max_e-1), x2 overflows
    v = []
    for x, y in [(min_sub, two), (min_sub, half), (min_sub, min_sub),
                 (max_sub, two), (max_sub, max_sub), (max_sub, one_eps),
                 (min_norm, half), (min_norm, min_norm), (min_norm, one_eps),
                 (one_eps, half), (one_eps, one_eps), (one_half, one_eps),
                 (maxf, maxf), (maxf, two), (maxf, one_eps), (pwr, two),
                 (two, two)]:
        for rm in range(5):
            v.append((fmt, x, y, rm))
    # E4M3FN: the exp=1111 finite region (256..448) and its overflow boundary
    if fmt == 6:
        one = enc(0, bias, 0)
        top_0 = enc(0, em, 0)            # 256 = 1.000 x 2^8
        top_m = enc(0, em, 6)            # 448 = 1.110 x 2^8 (largest finite)
        m15 = enc(0, bias, 7)            # 1.875
        m175 = enc(0, bias, 6)           # 1.75
        m15x = enc(0, bias, 4)           # 1.5
        for rm in range(5):
            v.append((fmt, top_m, one, rm))    # 448 x 1.0  = 448 (exact, exp=15 mant=6)
            v.append((fmt, top_0, one, rm))    # 256 x 1.0  = 256 (exp=15 mant=0)
            v.append((fmt, top_m, m15x, rm))   # 448 x 1.5  = 672 -> NaN OF|NX
            v.append((fmt, top_m, m175, rm))   # 448 x 1.75 = 784 -> NaN OF|NX
            v.append((fmt, top_0, m175, rm))   # 256 x 1.75 = 448 (exact, exp=15 mant=6)
            v.append((fmt, top_0, m15x, rm))   # 256 x 1.5  = 384 (exp=15 mant=4)
            v.append((fmt, top_0, m15, rm))    # 256 x 1.875 = 480 -> NaN OF|NX (mfrac=7 boundary)
            v.append((fmt, top_m, enc(0, bias - 1, 4), rm))  # 448 x 0.75 = 336 (tie 320/352)
        # full exp=1111 x exp=1111 sweep (all mantissa pairs, incl. NaN)
        for xm in range(8):
            for ym in range(8):
                for rm in range(5):
                    v.append((fmt, enc(0, em, xm), enc(0, em, ym), rm))
    # subnormal sweeps: exhaustive where cheap, structured subsets otherwise
    if fmt in (6, 5):                      # E4M3: 8x8, E5M2: 4x4
        for xm in range(1 << f):
            for ym in range(1 << f):
                for rm in range(5):
                    v.append((fmt, enc(0, 0, xm), enc(0, 0, ym), rm))
    if fmt == 2:                           # BF16 subnormal exhaustive 128x128
        for xm in range(1 << f):
            for ym in range(1 << f):
                for rm in range(5):
                    v.append((fmt, enc(0, 0, xm), enc(0, 0, ym), rm))
    if fmt in (1, 3, 4):                   # FP16/TF32/BF32 subnormal subsets
        pats = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255,
                256, 511, 512, 1023, 2047, 4095, 8191, 16383, 32767]
        pats = [p for p in pats if p < (1 << f)]
        for xm in pats:
            for ym in pats:
                for rm in range(5):
                    v.append((fmt, enc(0, 0, xm), enc(0, 0, ym), rm))
    return v


def emit(fmt, a, b, rm):
    r, fl = ref(fmt, a, b, rm)
    # cross-check against the independent grid-rounding model for EVERY vector
    r2, fl2 = indep_model.ref(fmt, a, b, rm)
    if (r, fl) != (r2, fl2):
        raise SystemExit(
            'MODEL MISMATCH fmt=%d a=%08x b=%08x rm=%d: bit-model=(%08x,%02x) '
            'fraction-model=(%08x,%02x)' % (fmt, a, b, rm, r, fl, r2, fl2))
    return '%d %08x %08x %d %08x %02x' % (fmt, a, b, rm, r, fl)


def main():
    out = []
    # FP formats: all specials x specials x all modes, plus boundaries
    for fmt in range(8):
        pats = fp_specials(fmt)
        for x in pats:
            for y in pats:
                for rm in range(5):
                    out.append(emit(fmt, x, y, rm))
        for (f_, x, y, rm) in fp_boundaries(fmt):
            out.append(emit(f_, x, y, rm))
    # INT formats: exhaustive for 4/8-bit, sampled for 16-bit
    for fmt, n in ((8, 4), (9, 4), (10, 8), (11, 8)):
        for x in range(1 << n):
            for y in range(1 << n):
                out.append(emit(fmt, x, y, 0))
    for fmt in (12, 13):
        mask = (1 << 16) - 1
        rng = xorshift(0x12345678)
        vals = [0, 1, 2, mask - 1, mask, 0x8000, 0x7FFF, 0x4000, 0x3FFF]
        for _ in range(20000):
            vals.append(next(rng) & mask)
        for x in vals:
            for y in vals[:12]:
                out.append(emit(fmt, x, y, 0))
    # ---- packed (SIMD) modes ----
    for fmt in range(14, 23):
        lw = lane_lw(fmt)
        sf = lane_scalar_fmt(fmt)
        n = 2 if fmt in (14, 15) else 4
        dsf = FMTS[sf]
        if 'n' in dsf:
            nrm = 1
            one = 1
            sp_lanes = [0, 1, (1 << (dsf['n'] - 1)), (1 << dsf['n']) - 1,
                        (1 << dsf['n']) - 2]
        else:
            nrm = 5
            sp = fp_specials(sf)
            sp_lanes = [((s >> (32 - lw)) & ((1 << lw) - 1)) for s in sp]
            one = (dsf['bias'] << (lw - 1 - dsf['ew']))   # 1.0 lane pattern
        # lane-splat specials (all lanes identical)
        for la in sp_lanes:
            splat = la
            for i in range(1, n):
                splat |= la << (i * lw)
            for rm in range(nrm):
                out.append(emit(fmt, splat, splat, rm))
        # per-lane special x special with the other lanes at 1.0
        for i in range(n):
            base = 0
            for j in range(n):
                if j != i:
                    base |= one << (j * lw)
            for x in sp_lanes:
                for y in sp_lanes:
                    for rm in range(nrm):
                        out.append(emit(fmt, base | (x << (i * lw)),
                                        base | (y << (i * lw)), rm))
        # per-lane exhaustive with other lanes at 1.0 (cross-lane integrity)
        if lw == 4:
            for i in range(n):
                base = 0
                for j in range(n):
                    if j != i:
                        base |= one << (j * lw)
                for x in range(1 << lw):
                    for y in range(1 << lw):
                        for rm in range(nrm):
                            out.append(emit(fmt, base | (x << (i * lw)),
                                            base | (y << (i * lw)), rm))
        if lw == 8:
            base = 0
            for j in range(1, n):
                base |= one << (j * lw)
            for x in range(1 << lw):
                for y in range(1 << lw):
                    for rm in range(nrm):
                        out.append(emit(fmt, base | x, base | y, rm))
        # random full-width vectors
        rng = xorshift(0x9ABCDEF0 + fmt)
        for _ in range(30000):
            wa = 0
            wb = 0
            for i in range(n):
                wa |= (next(rng) & ((1 << lw) - 1)) << (i * lw)
                wb |= (next(rng) & ((1 << lw) - 1)) << (i * lw)
            for rm in range(nrm):
                out.append(emit(fmt, wa, wb, rm))
    with open('tb/golden.txt', 'w') as fh:
        fh.write('\n'.join(out) + '\n')
    print('golden vectors: %d' % len(out))


def xorshift(seed):
    x = seed & 0xFFFFFFFF
    while True:
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        yield x & 0xFFFFFFFF


if __name__ == '__main__':
    main()
