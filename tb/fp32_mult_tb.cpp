//==============================================================================
// fp32_mult_tb.cpp : Verilator testbench for the multi-format fp32_mult
//==============================================================================
// Oracles:
//   ref_ieee : generic exact integer-arithmetic model (all 14 formats)
//   ref_fpu  : host double FPU, validates ref_ieee for FP32 (exact product in
//              double, single rounding to float)
//   tb/golden.txt : independent Python model (tb/gen_golden.py), replays
//              against the DUT and cross-checks ref_ieee for ALL formats
// Phases:
//   0. golden replay (all formats, incl. exhaustive INT4/INT8 and specials)
//   1. ref_ieee vs host FPU cross-check (FP32, RNE/RTZ/RDN/RUP)
//   2. directed FP32 edge-case table (clean + random back-pressure)
//   3. exhaustive narrow formats: FP4-E2M1, FP8-E4M3/E5M2, INT4, INT8
//   4. random mixed-format vectors (bubbles, stalls, mid-run reset)
//   5. back-to-back throughput check
//==============================================================================

#include <Vfp32_mult.h>
#include <verilated.h>
#include <verilated_vcd_c.h>

#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <random>
#include <string>
#include <vector>

static constexpr int LATENCY = 5;

static constexpr uint32_t FL_NX = 0x01u;
static constexpr uint32_t FL_UF = 0x02u;
static constexpr uint32_t FL_OF = 0x04u;
static constexpr uint32_t FL_NV = 0x10u;

struct Ref { uint64_t v; uint32_t fl; };

// ------------------------------ format table --------------------------------
struct FmtDef { int ew, f, bias, n; bool is_int, is_signed, no_inf; };
static FmtDef fmt_def(unsigned fmt) {
  switch (fmt) {
    case 0:  return { 8, 23, 127,  0, false, false, false};  // FP32
    case 1:  return { 5, 10,  15,  0, false, false, false};  // FP16
    case 2:  return { 8,  7, 127,  0, false, false, false};  // BF16
    case 3:  return { 8, 10, 127,  0, false, false, false};  // TF32
    case 4:  return { 8, 15, 127,  0, false, false, false};  // BF32
    case 5:  return { 5,  2,  15,  0, false, false, false};  // FP8 E5M2
    case 6:  return { 4,  3,   7,  0, false, false, true };  // FP8 E4M3FN
    case 7:  return { 2,  1,   1,  0, false, false, false};  // FP4 E2M1
    case 8:  return { 0,  0,   0,  4, true,  false, false};  // INT4U
    case 9:  return { 0,  0,   0,  4, true,  true,  false};  // INT4S
    case 10: return { 0,  0,   0,  8, true,  false, false};  // INT8U
    case 11: return { 0,  0,   0,  8, true,  true,  false};  // INT8S
    case 12: return { 0,  0,   0, 16, true,  false, false};  // INT16U
    default: return { 0,  0,   0, 16, true,  true,  false};  // INT16S
  }
}

// ----------------------- reference: exact generic model ---------------------
static int lane_lw(unsigned fmt) {
  switch (fmt) {
    case 14: case 15: return 16;
    case 16: case 17: case 19: case 20: return 8;
    case 18: case 21: case 22: default: return 4;
  }
}
static unsigned lane_scalar_fmt(unsigned fmt) {
  switch (fmt) {
    case 14: return 1;   // FP16
    case 15: return 2;   // BF16
    case 16: return 6;   // E4M3
    case 17: return 5;   // E5M2
    case 18: return 7;   // E2M1
    case 19: return 10;  // INT8U
    case 20: return 11;  // INT8S
    case 21: return 8;   // INT4U
    default: return 9;   // INT4S
  }
}
static Ref ref_ieee(unsigned fmt, uint32_t a, uint32_t b, unsigned rm) {
  if (fmt >= 14) {
    // packed mode: independent per-lane scalar operations; lane fields are
    // repacked into the scalar container positions (sign/exp/frac) and back
    const int lw = lane_lw(fmt);
    const int n = (fmt <= 15) ? 2 : 4;
    const unsigned sf = lane_scalar_fmt(fmt);
    const FmtDef d = fmt_def(sf);
    const bool is_int = d.is_int;
    const uint32_t lmask = (1u << lw) - 1;
    const uint32_t em = (1u << d.ew) - 1, fm = (1u << d.f) - 1;
    auto lane_to_scalar = [&](uint32_t l) -> uint32_t {
      if (is_int) return l;
      return ((l >> (lw - 1)) & 1u) << 31
           | (((l >> d.f) & em) << (31 - d.ew))
           | (l & fm);
    };
    const int rw = is_int ? 2 * lw : lw;   // per-lane result width
    auto scalar_to_lane = [&](uint64_t r) -> uint32_t {
      if (is_int) return (uint32_t)r & ((1u << rw) - 1);
      return ((uint32_t)(r >> 31) & 1u) << (lw - 1)
           | (((uint32_t)(r >> (31 - d.ew)) & em) << (lw - 1 - d.ew))
           | ((uint32_t)r & fm);
    };
    uint64_t res = 0;
    uint32_t fl = 0;
    for (int i = 0; i < n; i++) {
      const uint32_t la = (a >> (i * lw)) & lmask;
      const uint32_t lb = (b >> (i * lw)) & lmask;
      const Ref r = ref_ieee(sf, lane_to_scalar(la), lane_to_scalar(lb), rm);
      res |= (uint64_t)scalar_to_lane(r.v) << (i * rw);
      // 4-bit lane flags {NV, OF, UF, NX} from the 5-bit scalar flags
      fl |= (((r.fl & 0x10u) >> 1) | (r.fl & 0x7u)) << (4 * i);
    }
    return {res, fl};
  }
  const FmtDef d = fmt_def(fmt);
  if (d.is_int) {
    const uint32_t mask = (uint32_t)(((uint64_t)1 << d.n) - 1);
    uint64_t ma = a & mask, mb = b & mask;
    if (d.is_signed) {
      if (ma >> (d.n - 1)) ma = ((~ma) + 1) & mask;
      if (mb >> (d.n - 1)) mb = ((~mb) + 1) & mask;
    }
    const uint64_t p = ma * mb;
    const uint32_t m2 = (uint32_t)(((uint64_t)1 << (2 * d.n)) - 1);
    uint32_t r = (uint32_t)(p & m2);
    if (d.is_signed) {
      if (r & (1u << (2 * d.n - 1))) r |= ~m2;      // sign-extend to 32 bits
      const bool rs = ((a >> (d.n - 1)) ^ (b >> (d.n - 1))) & 1u;
      if (rs) r = 0u - r;
    }
    return {r, 0};
  }
  const int ew = d.ew, f = d.f, bias = d.bias;
  const uint32_t em = (1u << ew) - 1, fm = (1u << f) - 1;
  const uint32_t exp_all_pat = em << (31 - ew);
  const uint32_t qbit = 1u << (f - 1);
  const uint32_t rs = (a ^ b) & 0x80000000u;
  const uint32_t aE = (a >> (31 - ew)) & em, bE = (b >> (31 - ew)) & em;
  const uint32_t aF = a & fm, bF = b & fm;
  const bool aZ = aE == 0 && aF == 0, bZ = bE == 0 && bF == 0;
  const bool aN = d.no_inf ? (aE == em && aF == fm) : (aE == em && aF != 0);
  const bool bN = d.no_inf ? (bE == em && bF == fm) : (bE == em && bF != 0);
  const bool aI = d.no_inf ? false : (aE == em && aF == 0);
  const bool bI = d.no_inf ? false : (bE == em && bF == 0);
  const bool aSn = aN && !((aF >> (f - 1)) & 1u);
  const bool bSn = bN && !((bF >> (f - 1)) & 1u);
  uint32_t fl = (aSn || bSn) ? FL_NV : 0;
  if (aN || bN) {
    const uint32_t pl = aN ? aF : bF;
    return { rs | exp_all_pat | qbit | (pl & (qbit - 1)), fl };
  }
  if ((aZ && bI) || (bZ && aI)) {
    const uint32_t extra = d.no_inf ? (qbit - 1) : 0;
    return { rs | exp_all_pat | qbit | extra, fl | FL_NV };
  }
  if (aI || bI) return { rs | exp_all_pat, 0 };
  if (aZ || bZ) return { rs, 0 };

  const uint64_t sa = aE ? ((uint64_t)1 << f) | aF : aF;
  const uint64_t sb = bE ? ((uint64_t)1 << f) | bF : bF;
  const int ea = aE ? (int)aE : 1, eb = bE ? (int)bE : 1;
  const uint64_t p = sa * sb;
  const int lz = (int)__builtin_clzll(p) - 16;
  const int E = ea + eb - bias;
  const int E3 = E + (47 - 2 * f) - lz;
  const uint64_t pa = (p << lz) >> (23 - f);
  const uint32_t m = (uint32_t)(pa >> 24) & ((1u << (f + 1)) - 1);
  const uint32_t G = (uint32_t)(pa >> 23) & 1u;
  const uint32_t R = (uint32_t)(pa >> 22) & 1u;
  const bool S = (pa & (((uint64_t)1 << 22) - 1)) != 0;
  const bool sgn = rs != 0;
  auto inc = [&](uint32_t g, uint32_t r, bool s, bool lsb) -> uint32_t {
    switch (rm) {
      case 0: return g & (r | s | lsb);
      case 4: return g;
      case 1: return 0;
      case 2: return sgn ? (g | r | s) : 0;
      case 3: return sgn ? 0 : (g | r | s);
      default: return g & (r | s | lsb);
    }
  };
  if (E3 <= 0) {
    const int k = 25 - E3;
    const uint32_t field = (k >= 48) ? 0 : (uint32_t)(pa >> k) & fm;
    const uint32_t G2 = (k <= 48) ? (uint32_t)(pa >> (k - 1)) & 1u : 0;
    const uint32_t R2 = (k <= 49) ? (uint32_t)(pa >> (k - 2)) & 1u : 0;
    const bool S2 = (k <= 50) ? ((pa & (((uint64_t)1 << (k - 2)) - 1)) != 0) : true;
    const bool inex = G2 | R2 | S2;
    const uint32_t fld = field + inc(G2, R2, S2, field & 1u);
    if (fld == (1u << f))
      return { rs | (1u << (31 - ew)), inex ? (FL_NX | FL_UF) : 0 };
    return { rs | fld, inex ? (FL_NX | FL_UF) : 0 };
  }
  const uint32_t mr = m + inc(G, R, S, m & 1u);
  const bool carry = (mr >> (f + 1)) & 1u;
  const int Ef = E3 + (carry ? 1 : 0);
  const bool inex = G | R | S;
  const uint32_t frac = carry ? 0 : (mr & fm);
  // E4M3FN keeps exp field 2^EW-1 finite (256..448): overflow only when
  // Ef > 2^EW-1, or Ef == 2^EW-1 with an all-ones rounded mantissa (480).
  if (Ef > (int)em || (Ef == (int)em && (!d.no_inf || frac == fm))) {
    if (d.no_inf) return { rs | exp_all_pat | fm, FL_NX | FL_OF };
    const uint32_t max_pat = rs | ((em - 1) << (31 - ew)) | fm;
    const uint32_t inf_pat = rs | exp_all_pat;
    uint32_t v;
    switch (rm) {
      case 1: v = max_pat; break;
      case 2: v = sgn ? inf_pat : max_pat; break;
      case 3: v = sgn ? max_pat : inf_pat; break;
      default: v = inf_pat;
    }
    return { v, FL_NX | FL_OF };
  }
  return { rs | ((uint32_t)Ef << (31 - ew)) | frac, inex ? FL_NX : 0 };
}

// --------------------------- reference #2: host FPU -------------------------
static float u2f(uint32_t u) { float f; std::memcpy(&f, &u, sizeof f); return f; }
static uint32_t f2u(float f) { uint32_t u; std::memcpy(&u, &f, sizeof u); return u; }
static bool is_nan32(uint32_t u) { return (u & 0x7F800000u) == 0x7F800000u && (u & 0x7FFFFFu) != 0u; }
static bool is_inf32(uint32_t u) { return (u & 0x7FFFFFFFu) == 0x7F800000u; }
static bool is_zero32(uint32_t u) { return (u & 0x7FFFFFFFu) == 0u; }

static int fe_rm(unsigned rm) {
  switch (rm) {
    case 1: return FE_TOWARDZERO;
    case 2: return FE_DOWNWARD;
    case 3: return FE_UPWARD;
    default: return FE_TONEAREST;
  }
}
// Only valid when neither operand is NaN and not a 0*Inf pair.
static Ref ref_fpu(uint32_t a, uint32_t b, unsigned rm) {
  std::fesetround(fe_rm(rm));
  std::feclearexcept(FE_ALL_EXCEPT);
  volatile double da = (double)u2f(a);
  volatile double db = (double)u2f(b);
  volatile double p = da * db;
  volatile float f = (float)p;
  const int ex = std::fetestexcept(FE_INEXACT | FE_UNDERFLOW | FE_OVERFLOW);
  uint32_t fl = 0;
  if (ex & FE_INEXACT) fl |= FL_NX;
  if (ex & FE_UNDERFLOW) fl |= FL_UF;
  if (ex & FE_OVERFLOW) fl |= FL_OF;
  return { f2u(f), fl };
}

static bool fpu_rounding_probe() {
  // NOTE: the double source must be non-constant, otherwise GCC folds the
  // double->float conversion at compile time and the runtime rounding mode
  // is never exercised (probe would false-fail on Linux/GCC).
  volatile double dv = 0x1.000001p0;
  std::fesetround(FE_TOWARDZERO);
  volatile float fz = (float)dv;
  std::fesetround(FE_UPWARD);
  volatile float fu = (float)dv;
  std::fesetround(FE_TONEAREST);
  return f2u(fz) == 0x3F800000u && f2u(fu) == 0x3F800001u;
}
static bool fpu_flags_probe() {
  std::fesetround(FE_TONEAREST);
  std::feclearexcept(FE_ALL_EXCEPT);
  volatile float f1 = (float)0x1p128;
  bool ok = f2u(f1) == 0x7F800000u &&
            std::fetestexcept(FE_OVERFLOW | FE_INEXACT) == (FE_OVERFLOW | FE_INEXACT);
  std::feclearexcept(FE_ALL_EXCEPT);
  volatile float f2 = (float)0x1p-150;
  ok &= f2u(f2) == 0u &&
        std::fetestexcept(FE_UNDERFLOW | FE_INEXACT) == (FE_UNDERFLOW | FE_INEXACT);
  return ok;
}

// ------------------------------ input generation ----------------------------
static const uint32_t kSpecialsFP32[] = {
  0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u, 0x007FFFFFu, 0x807FFFFFu,
  0x00800000u, 0x80800000u, 0x3F800000u, 0xBF800000u, 0x3F000000u, 0x3FC00000u,
  0x40000000u, 0x7F000000u, 0x7F7FFFFFu, 0xFF7FFFFFu, 0x7F800000u, 0xFF800000u,
  0x7FC00000u, 0xFFC00000u, 0x7F800001u, 0x7FC12345u, 0xFF800123u, 0x3F800001u,
  0x3FFFFFFFu, 0x3E800000u, 0x3A83126Fu, 0x33000000u, 0x00000002u, 0x00400000u,
};
static uint32_t gen_input_fp32(std::mt19937_64& rng) {
  switch (rng() % 8u) {
    case 0: case 1:
      return (uint32_t)rng();
    case 2: case 3: case 4: {
      uint32_t v = (uint32_t)rng() & 0x807FFFFFu;
      if (rng() & 1u) v |= (uint32_t)(rng() % 255u) << 23;
      else            v &= (0x80000000u | (uint32_t)(rng() & 0x7FFFFFu));
      return v;
    }
    default:
      return kSpecialsFP32[rng() % (sizeof(kSpecialsFP32) / sizeof(kSpecialsFP32[0]))];
  }
}

static uint32_t gen_container(std::mt19937_64& rng, unsigned fmt) {
  if (fmt >= 14) {
    const int lw = lane_lw(fmt);
    const int n = (fmt <= 15) ? 2 : 4;
    uint32_t v = 0;
    for (int i = 0; i < n; i++)
      v |= ((uint32_t)rng() & ((1u << lw) - 1)) << (i * lw);
    return v;
  }
  const FmtDef d = fmt_def(fmt);
  if (d.is_int) return (uint32_t)rng() & ((1u << d.n) - 1);
  uint32_t v = (uint32_t)rng();
  v &= (1u << 31) | (((1u << d.ew) - 1) << (31 - d.ew)) | ((1u << d.f) - 1);
  return v;
}

static std::vector<uint32_t> fmt_specials(unsigned fmt) {
  if (fmt >= 14) {
    const int lw = lane_lw(fmt);
    const int n = (fmt <= 15) ? 2 : 4;
    const unsigned sf = lane_scalar_fmt(fmt);
    const std::vector<uint32_t> sp = fmt_specials(sf);
    std::vector<uint32_t> v;
    for (const uint32_t s : sp) {
      const uint32_t lane = (s >> (32 - lw)) & ((1u << lw) - 1);
      uint32_t w = 0;
      for (int i = 0; i < n; i++) w |= lane << (i * lw);
      v.push_back(w);
    }
    for (const uint32_t s1 : sp) {
      uint32_t w = 0;
      for (int i = 0; i < n; i++) {
        const uint32_t s = sp[(s1 + (uint32_t)i * 7u) % sp.size()];
        w |= ((s >> (32 - lw)) & ((1u << lw) - 1)) << (i * lw);
      }
      v.push_back(w);
    }
    return v;
  }
  const FmtDef d = fmt_def(fmt);
  std::vector<uint32_t> v;
  if (d.is_int) {
    v.push_back(0); v.push_back((1u << d.n) - 1);
    v.push_back(1u << (d.n - 1)); v.push_back(((1u << d.n) - 1) >> 1);
    return v;
  }
  const uint32_t em = (1u << d.ew) - 1, fm = (1u << d.f) - 1;
  auto enc = [&](uint32_t s, uint32_t e, uint32_t fr) {
    return (s << 31) | (e << (31 - d.ew)) | fr;
  };
  v = { enc(0,0,0), enc(1,0,0), enc(0,0,1), enc(1,0,1),
        enc(0,0,fm), enc(1,0,fm), enc(0,1,0), enc(1,1,0),
        enc(0,(uint32_t)d.bias,0), enc(1,(uint32_t)d.bias,0),
        enc(0,(uint32_t)d.bias,1), enc(1,(uint32_t)d.bias,1),
        enc(0,em-1,fm), enc(1,em-1,fm) };
  if (d.no_inf) {
    v.push_back(enc(0,em,fm)); v.push_back(enc(1,em,fm));
  } else {
    v.push_back(enc(0,em,0)); v.push_back(enc(1,em,0));
    v.push_back(enc(0,em,fm)); v.push_back(enc(1,em,fm));
    v.push_back(enc(0,em,1)); v.push_back(enc(1,em,1));
    if (d.f == 2) { v.push_back(enc(0,em,2)); v.push_back(enc(1,em,2)); }
    if (d.f == 1) { v.pop_back(); v.pop_back(); }
  }
  return v;
}

// ------------------------------ cross-check FP32 ----------------------------
static bool crosscheck(std::mt19937_64& rng, uint64_t n, bool check_flags) {
  uint64_t done = 0;
  while (done < n) {
    const uint32_t a = gen_input_fp32(rng), b = gen_input_fp32(rng);
    if (is_nan32(a) || is_nan32(b)) continue;
    if ((is_zero32(a) && is_inf32(b)) || (is_inf32(a) && is_zero32(b))) continue;
    for (unsigned rm = 0; rm < 4; rm++) {
      const Ref r1 = ref_ieee(0, a, b, rm);
      const Ref r2 = ref_fpu(a, b, rm);
      if (r1.v != r2.v || (check_flags && r1.fl != r2.fl)) {
        std::printf("CROSS-CHECK FAIL: a=%08x b=%08x rm=%u\n",
                    (unsigned)a, (unsigned)b, rm);
        std::printf("  ref_ieee: %08llx f=%02x   ref_fpu: %08x f=%02x\n",
                    (unsigned long long)r1.v, (unsigned)r1.fl,
                    (unsigned)r2.v, (unsigned)r2.fl);
        return false;
      }
    }
    done++;
  }
  return true;
}

// ------------------------------ directed vectors ----------------------------
struct DVec { uint32_t a, b; unsigned rm; uint32_t exp_v, exp_fl; const char* what; };
static const DVec kDirected[] = {
  {0x3F800000u, 0x3F800000u, 0, 0x3F800000u, 0,              "1.0 x 1.0"},
  {0x3FC00000u, 0x40000000u, 0, 0x40400000u, 0,              "1.5 x 2.0"},
  {0xC0200000u, 0xC0200000u, 0, 0x40C80000u, 0,              "-2.5 x -2.5"},
  {0x00000000u, 0xC0A00000u, 0, 0x80000000u, 0,              "+0 x -5 = -0"},
  {0x80000000u, 0x80000000u, 0, 0x00000000u, 0,              "-0 x -0 = +0"},
  {0x7F800000u, 0x40A00000u, 0, 0x7F800000u, 0,              "inf x 5"},
  {0xFF800000u, 0x7F800000u, 0, 0xFF800000u, 0,              "-inf x inf"},
  {0x7F800000u, 0x00000000u, 0, 0x7FC00000u, FL_NV,          "inf x 0 = qNaN, NV"},
  {0x7FC12345u, 0x3F800000u, 0, 0x7FC12345u, 0,              "qNaN x 1.0"},
  {0x7F800001u, 0x3F800000u, 0, 0x7FC00001u, FL_NV,          "sNaN x 1.0"},
  {0x7F800000u, 0xFF800123u, 0, 0xFFC00123u, FL_NV,          "inf x sNaN (payload from b)"},
  {0x7F7FFFFFu, 0x7F7FFFFFu, 0, 0x7F800000u, FL_OF | FL_NX,  "max x max RNE"},
  {0x7F7FFFFFu, 0x7F7FFFFFu, 1, 0x7F7FFFFFu, FL_OF | FL_NX,  "max x max RTZ"},
  {0x7F7FFFFFu, 0x7F7FFFFFu, 2, 0x7F7FFFFFu, FL_OF | FL_NX,  "max x max RDN"},
  {0x7F7FFFFFu, 0x7F7FFFFFu, 3, 0x7F800000u, FL_OF | FL_NX,  "max x max RUP"},
  {0xFF7FFFFFu, 0x7F7FFFFFu, 0, 0xFF800000u, FL_OF | FL_NX,  "-max x max RNE"},
  {0xFF7FFFFFu, 0x7F7FFFFFu, 3, 0xFF7FFFFFu, FL_OF | FL_NX,  "-max x max RUP"},
  {0xFF7FFFFFu, 0x7F7FFFFFu, 2, 0xFF800000u, FL_OF | FL_NX,  "-max x max RDN"},
  {0x7F7FFFFFu, 0x3F800001u, 0, 0x7F800000u, FL_OF | FL_NX,  "max x (1+2^-23) RNE"},
  {0x7F7FFFFFu, 0x3F800001u, 1, 0x7F7FFFFFu, FL_OF | FL_NX,  "max x (1+2^-23) RTZ"},
  {0x00000001u, 0x40000000u, 0, 0x00000002u, 0,              "min_sub x 2"},
  {0x00000001u, 0x3F000000u, 0, 0x00000000u, FL_NX | FL_UF,  "min_sub x 0.5 RNE tie"},
  {0x00000001u, 0x3F000000u, 4, 0x00000001u, FL_NX | FL_UF,  "min_sub x 0.5 RNA"},
  {0x00000001u, 0x3F000000u, 1, 0x00000000u, FL_NX | FL_UF,  "min_sub x 0.5 RTZ"},
  {0x00000001u, 0x3F000000u, 3, 0x00000001u, FL_NX | FL_UF,  "min_sub x 0.5 RUP"},
  {0x00000001u, 0x00000001u, 0, 0x00000000u, FL_NX | FL_UF,  "min_sub x min_sub"},
  {0x3F800001u, 0x3F000000u, 0, 0x3F000001u, 0,              "(1+2^-23) x 0.5 exact"},
  {0x3F800001u, 0x3F000000u, 4, 0x3F000001u, 0,              "(1+2^-23) x 0.5 RNA exact"},
  {0x3FC00000u, 0x3F800001u, 0, 0x3FC00002u, FL_NX,          "1.5 x (1+2^-23) RNE tie->even"},
  {0x3FC00000u, 0x3F800001u, 1, 0x3FC00001u, FL_NX,          "1.5 x (1+2^-23) RTZ"},
  {0x3FC00000u, 0x3F800001u, 4, 0x3FC00002u, FL_NX,          "1.5 x (1+2^-23) RNA"},
  {0x3FC00000u, 0x3F800001u, 2, 0x3FC00001u, FL_NX,          "1.5 x (1+2^-23) RDN"},
  {0x3FC00000u, 0x3F800001u, 3, 0x3FC00002u, FL_NX,          "1.5 x (1+2^-23) RUP"},
  {0x00400000u, 0x3F800001u, 0, 0x00400000u, FL_NX | FL_UF,  "2^-127 x (1+2^-23) subnormal tie->even"},
  {0x007FFFFFu, 0x40000000u, 0, 0x00FFFFFEu, 0,              "max_sub x 2 exact (normal)"},
  {0x007FFFFFu, 0x007FFFFFu, 0, 0x00000000u, FL_NX | FL_UF,  "max_sub x max_sub"},
  {0x3FFFFFFFu, 0x3F800001u, 0, 0x40000000u, FL_NX,          "(2-2^-23) x (1+2^-23) -> 2.0"},
  {0x7F000000u, 0x40000000u, 0, 0x7F800000u, FL_OF | FL_NX,  "2^127 x 2 overflow"},
  {0x7F000000u, 0x40000000u, 1, 0x7F7FFFFFu, FL_OF | FL_NX,  "2^127 x 2 RTZ"},
  {0x00800000u, 0x3F000000u, 0, 0x00400000u, 0,              "min_normal x 0.5 exact"},
  {0x00800000u, 0x00800000u, 0, 0x00000000u, FL_NX | FL_UF,  "min_normal x min_normal"},
  {0x00400000u, 0x3FC00000u, 0, 0x00600000u, 0,              "2^-127 x 1.5 exact"},
  {0x00400000u, 0x3F800001u, 4, 0x00400001u, FL_NX | FL_UF,  "2^-127 x (1+2^-23) RNA"},
  {0x3F800000u, 0x7FC00007u, 0, 0x7FC00007u, 0,              "1.0 x qNaN"},
  {0xFFC00001u, 0x3F800000u, 0, 0xFFC00001u, 0,              "-qNaN x 1.0"},
  {0x7FC00001u, 0x7F800000u, 0, 0x7FC00001u, 0,              "qNaN x inf (no NV)"},
  {0x00000000u, 0x7F7FFFFFu, 0, 0x00000000u, 0,              "0 x max"},
  {0x80000001u, 0x3F000000u, 0, 0x80000000u, FL_NX | FL_UF,  "-min_sub x 0.5 RNE -> -0"},
  {0x80000001u, 0x3F000000u, 2, 0x80000001u, FL_NX | FL_UF,  "-min_sub x 0.5 RDN"},
  {0x80000001u, 0x3F000000u, 3, 0x80000000u, FL_NX | FL_UF,  "-min_sub x 0.5 RUP -> -0"},
  {0x7F800001u, 0xFFC00000u, 0, 0xFFC00001u, FL_NV,          "sNaN x qNaN (sign = xor)"},
  {0x7FC11111u, 0x7FC22222u, 0, 0x7FC11111u, 0,              "qNaN x qNaN"},
  {0x3F800000u, 0xFF800000u, 0, 0xFF800000u, 0,              "1.0 x -inf"},
  {0x00000001u, 0x7F800000u, 0, 0x7F800000u, 0,              "min_sub x inf"},
  {0xFF7FFFFFu, 0xFF7FFFFFu, 0, 0x7F800000u, FL_OF | FL_NX,  "-max x -max"},
  {0x3F800001u, 0x3F800001u, 0, 0x3F800002u, FL_NX,          "(1+2^-23)^2"},
  {0x00800000u, 0x3F800001u, 0, 0x00800001u, 0,              "min_normal x (1+2^-23) exact"},
  {0x00800000u, 0x3F800001u, 1, 0x00800001u, 0,              "min_normal x (1+2^-23) RTZ exact"},
  {0x80400000u, 0x3F800001u, 0, 0x80400000u, FL_NX | FL_UF,  "-2^-127 x (1+2^-23) tie->even"},
  {0x80400000u, 0x3F800001u, 4, 0x80400001u, FL_NX | FL_UF,  "-2^-127 x (1+2^-23) RNA"},
  {0x80400000u, 0x3FC00000u, 0, 0x80600000u, 0,              "-2^-127 x 1.5 exact"},
  {0x007FFFFFu, 0x3F800001u, 0, 0x00800000u, FL_NX | FL_UF,  "max_sub x (1+2^-23) -> min normal"},
  {0x007FFFFFu, 0x3F800001u, 1, 0x007FFFFFu, FL_NX | FL_UF,  "max_sub x (1+2^-23) RTZ"},
};

// ------------------------------- DUT driver ---------------------------------
struct SimStats { bool ok; uint64_t cycles; uint64_t consumed; uint64_t dropped; };

// gen: fills a,b,fmt,rm,ref,id; returns false when exhausted.
static SimStats run_stream(Vfp32_mult& dut, VerilatedVcdC* tfp, uint64_t& t,
                           std::mt19937_64& rng, bool allow_stall, uint64_t reset_at,
                           uint32_t bubble_pct, bool dbg,
                           std::function<bool(uint32_t&, uint32_t&, uint32_t&,
                                              uint32_t&, Ref&, uint64_t&)> gen) {
  struct Queued { uint32_t a, b, fmt, rm; Ref r; uint64_t id; };
  std::deque<Queued> eq;
  uint64_t accepted = 0, consumed = 0, dropped = 0, generated = 0, cycles = 0;
  bool last_inv = false;
  uint32_t la = 0, lb = 0, lfmt = 0, lrm = 0;
  Ref lref{0, 0};
  uint64_t lid = 0;
  bool ordy = true;     // out_ready during the cycle that just ended
  bool ov = false;      // out_valid during the cycle that just ended
  bool irdy = true;     // in_ready during the cycle that just ended
  bool more = true;
  bool reset_done = false;

  auto fail = [&](const Queued* q, const char* why) {
    std::printf("  FAIL @cycle %llu: %s\n", (unsigned long long)cycles, why);
    std::printf("    got: result=%016llx fflags=%04x\n",
                (unsigned long long)dut.result, (unsigned)dut.fflags);
    if (q)
      std::printf("    vector id %llu: fmt=%u a=%08x b=%08x rm=%u  expected: result=%016llx fflags=%04x\n",
                  (unsigned long long)q->id, (unsigned)q->fmt, (unsigned)q->a,
                  (unsigned)q->b, (unsigned)q->rm,
                  (unsigned long long)q->r.v, (unsigned)q->r.fl);
  };

  // Cycle model: {ov, ordy, irdy} are the values that held during the cycle
  // that just ended. The DUT presents its registered result for the whole
  // cycle and samples out_ready at the posedge, so the consumer must take
  // the result BEFORE the posedge -- i.e. at the top of the loop iteration.
  while (consumed < accepted || more || dut.out_valid) {
    if (cycles > 4 * (generated + accepted) + 100000) {
      std::printf("  FAIL: simulation did not converge (cycle %llu)\n",
                  (unsigned long long)cycles);
      return {false, cycles, consumed, dropped};
    }
    // ---- consume the output presented during the cycle that just ended ----
    if (ov && ordy) {
      if (eq.empty()) { fail(nullptr, "output with no queued expectation"); return {false, cycles, consumed, dropped}; }
      const Queued q = eq.front(); eq.pop_front();
      if (dbg && cycles < 200)
        std::printf("    [dbg] c%llu CONSUME id%llu fmt=%u (a=%08x b=%08x rm=%u exp %016llx f=%02x) got %016llx f=%02x\n",
                    (unsigned long long)cycles, (unsigned long long)q.id, (unsigned)q.fmt,
                    (unsigned)q.a, (unsigned)q.b, (unsigned)q.rm,
                    (unsigned long long)q.r.v, (unsigned)q.r.fl,
                    (unsigned long long)dut.result, (unsigned)dut.fflags);
      if (dut.result != q.r.v || (uint32_t)dut.fflags != q.r.fl) {
        fail(&q, "result/flags mismatch");
        return {false, cycles, consumed, dropped};
      }
      consumed++;
    }
    // ---- posedge ----
    dut.clk = 1; dut.eval();
    if (tfp) { tfp->dump(t); } t += 5000;
    // ---- negedge: bookkeeping for the next cycle ----
    dut.clk = 0; dut.eval();
    if (tfp) { tfp->dump(t); } t += 5000;
    if (last_inv && irdy) {
      eq.push_back({la, lb, lfmt, lrm, lref, lid}); accepted++;
      if (dbg && cycles < 200)
        std::printf("    [dbg] c%llu PUSH id%llu fmt=%u (a=%08x b=%08x rm=%u -> %016llx f=%02x)\n",
                    (unsigned long long)cycles, (unsigned long long)lid, (unsigned)lfmt,
                    (unsigned)la, (unsigned)lb, (unsigned)lrm,
                    (unsigned long long)lref.v, (unsigned)lref.fl);
    }
    if (!last_inv || irdy) {
      if (more) {
        const bool got = gen(la, lb, lfmt, lrm, lref, lid);
        if (got) {
          generated++;
          last_inv = !(bubble_pct && (rng() % 100u) < bubble_pct);
        } else {
          more = false; last_inv = false;
        }
      } else last_inv = false;
    }
    dut.in_valid = last_inv;
    dut.a = la; dut.b = lb; dut.fmt = lfmt; dut.rm = lrm;
    ordy = more ? ((allow_stall && (rng() % 100u) >= 88u) ? false : true) : true;
    dut.out_ready = ordy;
    ov   = dut.out_valid;
    irdy = !(ov && !ordy);
    cycles++;

    // ---- optional mid-run reset ----
    if (reset_at > 0 && !reset_done && consumed >= reset_at) {
      reset_done = true;
      dut.in_valid = 0; dut.out_ready = 1;
      dut.rst_n = 0;
      for (int i = 0; i < 4; i++) {
        dut.clk = 1; dut.eval(); if (tfp) { tfp->dump(t); } t += 5000;
        dut.clk = 0; dut.eval(); if (tfp) { tfp->dump(t); } t += 5000;
      }
      dut.rst_n = 1;
      dropped += (accepted - consumed);   // in-flight results lost by reset
      eq.clear(); accepted = 0; consumed = 0;
      last_inv = false; more = true; ordy = true; ov = false; irdy = true;
    }
  }
  return {true, cycles, consumed, dropped};
}

// ------------------------------- golden replay ------------------------------
struct GRec { uint32_t fmt, a, b, rm, fl; uint64_t res; };
static bool load_golden(const std::string& path, std::vector<GRec>& v) {
  FILE* f = std::fopen(path.c_str(), "r");
  if (!f) return false;
  unsigned fmt, a, b, rm, fl;
  unsigned long long res;
  while (std::fscanf(f, "%u %x %x %u %llx %x", &fmt, &a, &b, &rm, &res, &fl) == 6)
    v.push_back({(uint32_t)fmt, (uint32_t)a, (uint32_t)b, (uint32_t)rm,
                 (uint32_t)fl, (uint64_t)res});
  std::fclose(f);
  return true;
}

// ---------------------------------- main ------------------------------------
int main(int argc, char** argv) {
  uint64_t seed = 0xC0FFEEull, n_cross = 1000000, n_vec = 2000000;
  std::string golden_path = "tb/golden.txt";
  bool trace = false;
  for (int i = 1; i < argc; i++) {
    const std::string s = argv[i];
    if (s == "--seed" && i + 1 < argc) seed = std::strtoull(argv[++i], nullptr, 0);
    else if (s == "--cross" && i + 1 < argc) n_cross = std::strtoull(argv[++i], nullptr, 0);
    else if (s == "--n" && i + 1 < argc) n_vec = std::strtoull(argv[++i], nullptr, 0);
    else if (s == "--golden" && i + 1 < argc) golden_path = argv[++i];
    else if (s == "--trace") trace = true;
    else {
      std::printf("usage: %s [--seed N] [--cross N] [--n N] [--golden FILE] [--trace]\n", argv[0]);
      return 2;
    }
  }

  std::printf("== fp32_mult multi-format verification ==\n");
  std::printf("seed=%llu  cross=%llu  random=%llu\n",
              (unsigned long long)seed, (unsigned long long)n_cross,
              (unsigned long long)n_vec);

  if (!fpu_rounding_probe()) {
    std::printf("FATAL: host FPU ignores fesetround(); rebuild with -frounding-math\n");
    return 2;
  }
  const bool check_flags = fpu_flags_probe();
  if (!check_flags)
    std::printf("WARNING: host FPU does not expose IEEE flags; cross-check compares results only\n");

  Vfp32_mult dut;
  VerilatedVcdC* tfp = nullptr;
  uint64_t t = 0;
  if (trace) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    dut.trace(tfp, 99);
    tfp->open("fp32_mult.vcd");
  }
  dut.clk = 0; dut.rst_n = 0; dut.in_valid = 0; dut.out_ready = 1; dut.eval();
  for (int i = 0; i < 8; i++) {
    dut.clk = 1; dut.eval(); if (tfp) { tfp->dump(t); } t += 5000;
    dut.clk = 0; dut.eval(); if (tfp) { tfp->dump(t); } t += 5000;
  }
  dut.rst_n = 1; dut.eval();

  std::mt19937_64 rng(seed ^ 0x9E3779B97F4A7C15ull);

  // ---- phase 0: golden replay (all formats) ----
  std::printf("[0/5] golden replay (independent Python oracle, all formats) ...\n");
  {
    std::vector<GRec> gv;
    if (!load_golden(golden_path, gv)) {
      std::printf("      golden file '%s' not found -- run 'python3 tb/gen_golden.py' (phase skipped)\n",
                  golden_path.c_str());
    } else {
      uint64_t bad = 0;
      for (const auto& g : gv) {
        const Ref r = ref_ieee((unsigned)g.fmt, g.a, g.b, (unsigned)g.rm);
        if (r.v != g.res || r.fl != g.fl) {
          if (bad < 5)
            std::printf("      REF MISMATCH fmt=%u a=%08x b=%08x rm=%u: c++=%016llx/%02x golden=%016llx/%02x\n",
                        (unsigned)g.fmt, (unsigned)g.a, (unsigned)g.b, (unsigned)g.rm,
                        (unsigned long long)r.v, (unsigned)r.fl,
                        (unsigned long long)g.res, (unsigned)g.fl);
          bad++;
        }
      }
      if (bad) {
        std::printf("  FAIL: %llu C++-ref vs golden mismatches\n", (unsigned long long)bad);
        return 1;
      }
      std::printf("      C++ ref vs golden: %zu vectors agree\n", gv.size());
      size_t idx = 0;
      auto st = run_stream(dut, tfp, t, rng, false, 0, 0, false,
        [&](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) -> bool {
          if (idx >= gv.size()) return false;
          const GRec& g = gv[idx];
          a = g.a; b = g.b; fmt = g.fmt; rm = g.rm;
          r = {g.res, g.fl};
          id = idx++;
          return true;
        });
      if (!st.ok) return 1;
      std::printf("      DUT vs golden: %zu vectors passed (%llu cycles)\n",
                  gv.size(), (unsigned long long)st.cycles);
    }
  }

  // ---- phase 1: FP32 cross-check vs host FPU ----
  std::printf("[1/5] ref_ieee(FP32) vs host FPU ...\n");
  {
    std::mt19937_64 cr(seed);
    if (!crosscheck(cr, n_cross, check_flags)) return 1;
  }
  std::printf("      passed (%llu vectors x 4 modes)\n", (unsigned long long)n_cross);

  // ---- phase 2: directed FP32 ----
  const size_t n_dir = sizeof(kDirected) / sizeof(kDirected[0]);
  std::printf("[2/5] directed FP32 edge cases (%zu vectors) ...\n", n_dir);
  {
    size_t idx = 0;
    auto st = run_stream(dut, tfp, t, rng, false, 0, 0, false,
      [&](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) -> bool {
        if (idx >= n_dir) return false;
        a = kDirected[idx].a; b = kDirected[idx].b; fmt = 0; rm = kDirected[idx].rm;
        r = {kDirected[idx].exp_v, kDirected[idx].exp_fl};
        id = idx++;
        return true;
      });
    if (!st.ok) return 1;
    std::printf("      passed (%llu cycles)\n", (unsigned long long)st.cycles);
  }
  {
    size_t idx = 0;
    auto st = run_stream(dut, tfp, t, rng, true, 0, 0, false,
      [&](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) -> bool {
        if (idx >= n_dir) return false;
        a = kDirected[idx].a; b = kDirected[idx].b; fmt = 0; rm = kDirected[idx].rm;
        r = {kDirected[idx].exp_v, kDirected[idx].exp_fl};
        id = idx++;
        return true;
      });
    if (!st.ok) return 1;
    std::printf("      passed with random back-pressure\n");
  }

  // ---- phase 3: exhaustive narrow formats ----
  std::printf("[3/5] exhaustive narrow formats (FP4/FP8/INT4/INT8) ...\n");
  {
    // FP4-E2M1: 16x16x5, E4M3/E5M2: 256x256x5, INT4: 16x16, INT8: 256x256
    static const struct { unsigned fmt; unsigned n; unsigned nrm; } jobs[] = {
      { 7, 16, 5 }, { 6, 256, 5 }, { 5, 256, 5 }, { 8, 16, 1 }, { 9, 16, 1 },
      { 10, 256, 1 }, { 11, 256, 1 },
    };
    for (const auto& j : jobs) {
      struct It { unsigned fmt, n, nrm; uint64_t a, b, rm; bool done; } it = {j.fmt, j.n, j.nrm, 0, 0, 0, false};
      auto st = run_stream(dut, tfp, t, rng, false, 0, 0, false,
        [it](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) mutable -> bool {
          if (it.done) return false;
          a = (uint32_t)it.a; b = (uint32_t)it.b; fmt = it.fmt; rm = (uint32_t)it.rm;
          r = ref_ieee(it.fmt, (uint32_t)it.a, (uint32_t)it.b, (uint32_t)it.rm);
          id = it.a * it.n * it.nrm + it.b * it.nrm + it.rm;
          if (++it.rm >= it.nrm) { it.rm = 0; if (++it.b >= it.n) { it.b = 0; if (++it.a >= it.n) it.done = true; } }
          return true;
        });
      if (!st.ok) return 1;
      std::printf("      fmt=%u (%u x %u x %u) passed\n", j.fmt, j.n, j.n, j.nrm);
    }
  }

  // ---- phase 4: random mixed formats ----
  std::printf("[4/5] random mixed-format vectors (bubbles, stalls, mid-run reset) ...\n");
  {
    auto st = run_stream(dut, tfp, t, rng, true, n_vec / 2, 10, false,
      [&](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) -> bool {
        static uint64_t gen = 0;
        if (gen >= n_vec) return false;
        fmt = (uint32_t)(rng() % 23u);
        rm = (uint32_t)(rng() % 5u);
        const auto sp = fmt_specials((unsigned)fmt);
        if (rng() % 4u == 0) {
          a = sp[rng() % sp.size()];
          b = (rng() % 2u) ? gen_container(rng, (unsigned)fmt) : sp[rng() % sp.size()];
        } else {
          a = gen_container(rng, (unsigned)fmt);
          b = gen_container(rng, (unsigned)fmt);
        }
        r = ref_ieee((unsigned)fmt, a, b, (unsigned)rm);
        id = gen++;
        return true;
      });
    if (!st.ok) return 1;
    std::printf("      passed (%llu vectors, %llu cycles, %llu dropped by reset)\n",
                (unsigned long long)n_vec, (unsigned long long)st.cycles,
                (unsigned long long)st.dropped);
  }

  // ---- phase 5: throughput ----
  std::printf("[5/5] back-to-back throughput check ...\n");
  {
    const uint64_t n_tp = 200000;
    auto st = run_stream(dut, tfp, t, rng, false, 0, 0, false,
      [&](uint32_t& a, uint32_t& b, uint32_t& fmt, uint32_t& rm, Ref& r, uint64_t& id) -> bool {
        static uint64_t gen = 0;
        if (gen >= n_tp) return false;
        fmt = (uint32_t)(rng() % 23u);
        rm = (uint32_t)(rng() % 5u);
        a = gen_container(rng, (unsigned)fmt);
        b = gen_container(rng, (unsigned)fmt);
        r = ref_ieee((unsigned)fmt, a, b, (unsigned)rm);
        id = gen++;
        return true;
      });
    if (!st.ok) return 1;
    if (st.consumed != n_tp) {
      std::printf("  FAIL: consumed %llu != %llu\n",
                  (unsigned long long)st.consumed, (unsigned long long)n_tp);
      return 1;
    }
    if (st.cycles != n_tp + LATENCY + 1) {
      std::printf("  FAIL: latency drift (cycles=%llu, expected %llu)\n",
                  (unsigned long long)st.cycles,
                  (unsigned long long)(n_tp + LATENCY + 1));
      return 1;
    }
    std::printf("      passed: %llu results in %llu cycles (latency %d, 1 result/cycle)\n",
                (unsigned long long)n_tp, (unsigned long long)st.cycles, LATENCY);
  }

  dut.final();
  if (tfp) { tfp->close(); delete tfp; }
  std::printf("ALL PHASES PASSED\n");
  return 0;
}
