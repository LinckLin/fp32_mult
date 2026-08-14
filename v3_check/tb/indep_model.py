#!/usr/bin/env python3
# ==============================================================================
# indep_model.py : a DELIBERATELY DIFFERENT reference formulation
# ==============================================================================
# This model derives results from the exact rational value (fractions.Fraction)
# by locating the two adjacent representable grid points and rounding between
# them. It shares NO code path with the bit-twiddling model in gen_golden.py
# (no LZ, no shift normalization, no align shift, no k=25-E3 guards). It is
# cross-checked against gen_golden.py for every emitted golden vector, giving
# the project a genuine second (spec-derived) oracle for ALL formats.
#
# Conventions (must match fp32_defs.vh / README):
#   E4M3FN: no Inf; exp field 2^EW-1 with mantissa != all-ones is FINITE
#           (256..448); overflow -> NaN (S.1111.111) + OF|NX.
#   Underflow: tininess BEFORE rounding (any inexact result whose exact
#           magnitude is below 2^(1-bias) sets UF, incl. rounds-into-normal).
#   INT: two's-complement product, 32-bit wrap, no flags.
# ==============================================================================

from fractions import Fraction

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
    mask = (1 << n) - 1
    if d['signed']:
        va = a & mask
        vb = b & mask
        if va >> (n - 1):
            va -= 1 << n            # interpret as two's complement
        if vb >> (n - 1):
            vb -= 1 << n
        return (va * vb) & 0xFFFFFFFF, 0
    return ((a & mask) * (b & mask)) & 0xFFFFFFFF, 0


def inc_round(t, lsb, sgn, rm):
    # rounding increment for fraction t in [0,1), lsb = kept LSB parity
    half = Fraction(1, 2)
    if rm == 0:                       # RNE
        return 1 if (t > half or (t == half and lsb == 1)) else 0
    if rm == 4:                       # RNA
        return 1 if t >= half else 0
    if rm == 1:                       # RTZ
        return 0
    if rm == 2:                       # RDN
        return 1 if (sgn and t > 0) else 0
    if rm == 3:                       # RUP
        return 1 if ((not sgn) and t > 0) else 0
    return 0


def ref_fp(d, a, b, rm):
    ew, f, bias = d['ew'], d['f'], d['bias']
    no_inf = d.get('no_inf', False)
    em = (1 << ew) - 1
    fm = (1 << f) - 1
    exp_all_pat = em << (31 - ew)
    qbit = 1 << (f - 1)

    def fields(x):
        return ((x >> 31) & 1, (x >> (31 - ew)) & em, x & fm)

    sa, ea, fa = fields(a)
    sb, eb, fb = fields(b)
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

    # exact value as a Fraction: v = m * 2^(e-bias-f)
    def value(s, e, fr):
        if e == 0:
            return Fraction(fr, 1 << (bias - 1 + f)) if fr else Fraction(0)
        if e >= bias:
            return Fraction((1 << f) + fr, 1 << f) * (1 << (e - bias))
        return Fraction((1 << f) + fr, 1 << f) / (1 << (bias - e))

    va = value(sa, ea, fa)
    vb = value(sb, eb, fb)
    v = va * vb
    if v == 0:
        return rs << 31, 0
    av = abs(v)
    num, den = av.numerator, av.denominator

    # exponent k = floor(log2(av)); E = k + bias is the biased exponent
    k = num.bit_length() - den.bit_length()
    if k >= 0:
        if num < (den << k):
            k -= 1
    else:
        if (num << -k) < den:
            k -= 1
    E = k + bias

    if E < 1:
        # subnormal grid: field = round(av * 2^(bias+f-1))
        sh = bias + f - 1
        sn = num << sh if sh >= 0 else num
        d2 = den if sh >= 0 else den << -sh
        mi = sn // d2
        rem = sn - mi * d2
        inex = rem > 0
        mi += inc_round(Fraction(rem, d2), mi & 1, rs, rm)
        if mi == (1 << f):
            # rounds up into the smallest normal (tininess is pre-rounding)
            return (rs << 31) | (1 << (31 - ew)), (FL_NX | FL_UF) if inex else 0
        return (rs << 31) | mi, (FL_NX | FL_UF) if inex else 0

    # normal grid: mi = floor(av * 2^(f-k)), fraction t = remainder
    sh = f - k
    sn = num << sh if sh >= 0 else num
    d2 = den if sh >= 0 else den << -sh
    mi = sn // d2
    rem = sn - mi * d2
    inex = rem > 0
    mi += inc_round(Fraction(rem, d2), mi & 1, rs, rm)
    if mi == (1 << (f + 1)):
        mi = 1 << f
        E += 1
    # overflow: above the largest finite; E4M3 keeps E == em finite except
    # the all-ones mantissa (value 480 > max 448)
    if E > em or (E == em and (not no_inf or (mi - (1 << f)) == fm)):
        if no_inf:
            return (rs << 31) | exp_all_pat | fm, FL_NX | FL_OF
        max_pat = (rs << 31) | ((em - 1) << (31 - ew)) | fm
        inf_pat = (rs << 31) | exp_all_pat
        if rm == 1:
            vv = max_pat
        elif rm == 2:
            vv = inf_pat if rs else max_pat
        elif rm == 3:
            vv = max_pat if rs else inf_pat
        else:
            vv = inf_pat
        return vv, FL_NX | FL_OF
    return (rs << 31) | (E << (31 - ew)) | (mi - (1 << f)), FL_NX if inex else 0
