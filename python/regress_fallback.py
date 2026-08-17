# -*- coding: utf-8 -*-
"""
Rate-1 zero-LLR fallback regression suite.

Covers:
  Test 1: known minimal counterexample (N=4, frozen=1100, LLR=[-40,-40,40,-40])
  Test 2: random quantized soft LLRs (must include 0), N=4..1024, >1000 groups
  Test 3: zero-heavy corner cases (all-zero / single-zero / multi-zero / mixed)
  Test 4: existing suites rerun (sc_fast_model main + appendix H check)
  Stats : fast-node count and fallback count
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from sc_fast_model import FastDecoder
from sc_model import Decoder as PipeDecoder, make_frozen_mask


def run_pair(n_log, frozen, llrs):
    pipe = PipeDecoder(True, n_log, frozen)
    pipe.load(llrs)
    pipe.run_decode()
    fast = FastDecoder(n_log, frozen)
    fast.load(llrs)
    fast.run_decode()
    return fast.out_u, pipe.out_u, fast.ctrl.fallback_count, \
        fast.cycle_count, pipe.cycle_count


def test1():
    print("== Test 1: known counterexample (N=4 frozen=1100) ==")
    n_log, frozen, llrs = 2, [1, 1, 0, 0], [-40, -40, 40, -40]
    uf, up, fb, fc, pc = run_pair(n_log, frozen, llrs)
    s_f = "".join(str(b) for b in uf)
    s_p = "".join(str(b) for b in up)
    print(f"  baseline={s_p} fast={s_f} fallback={fb} fast_cyc={fc} pipe_cyc={pc}")
    assert s_p == "0001" and s_f == "0001", "counterexample mismatch"
    assert fb > 0, "counterexample must trigger Rate-1 fallback"
    print("  PASS (fallback triggered)")


def test2(seed=20260811):
    print("== Test 2: random soft LLR (must include 0), bit-exact ==")
    rng = random.Random(seed)
    total = 0
    fall = 0
    fast_ok = 0
    groups = [
        (2, 200), (3, 200), (4, 200), (6, 200), (8, 200), (9, 80), (10, 60),
    ]
    for n_log, cnt in groups:
        n = 1 << n_log
        for _ in range(cnt):
            k = rng.choice([1, n // 4, n // 2, (3 * n) // 4, max(1, n - 1), n])
            frozen = make_frozen_mask(n_log, k)
            # 量化软 LLR：-80..+80，确保至少一个 0
            llrs = [rng.randint(-80, 80) for _ in range(n)]
            zero_idx = rng.randrange(n)
            llrs[zero_idx] = 0
            uf, up, fb, fc, pc = run_pair(n_log, frozen, llrs)
            assert uf == up, f"N={n} K={k} zero@{zero_idx} bit mismatch"
            total += 1
            fall += (1 if fb > 0 else 0)
        print(f"  N={n}: {cnt} groups OK")
    print(f"  total={total} groups, with-fallback={fall}")
    assert total >= 1000, f"need >=1000 groups, got {total}"
    assert fall > 0, "random zero-LLR suite should trigger some fallbacks"
    print("  PASS")


def test3():
    print("== Test 3: zero-heavy corner cases ==")
    rng = random.Random(7)
    cases = 0
    for n_log in (2, 3, 4, 6):
        n = 1 << n_log
        for _ in range(60):
            k = rng.choice([1, n // 2, n])
            frozen = make_frozen_mask(n_log, k)
            style = rng.randrange(4)
            if style == 0:
                llrs = [0] * n                      # 全 0
            elif style == 1:
                llrs = [0] * n                      # 单个 0
                pos = rng.randrange(n)
                for i in range(n):
                    llrs[i] = rng.choice([-64, 64]) if i != pos else 0
            elif style == 2:
                llrs = [rng.choice([-40, 0, 40]) for _ in range(n)]  # 多个 0
            else:
                llrs = [rng.randint(-80, 80) for _ in range(n)]      # 混合
                for _ in range(rng.randint(1, n // 2)):
                    llrs[rng.randrange(n)] = 0
            uf, up, fb, _, _ = run_pair(n_log, frozen, llrs)
            assert uf == up, f"zero-heavy N={n} K={k} style={style} mismatch"
            cases += 1
    print(f"  {cases} zero-heavy cases OK")
    print("  PASS")


def test4():
    print("== Test 4: original suites rerun ==")
    import sc_fast_model
    sc_fast_model.main()
    import check_appendix_h_fast
    p, f = check_appendix_h_fast.main()
    assert f == 0, f"appendix payload check FAIL count={f}"
    cp, cf = check_appendix_h_fast.check_control_tvs()
    assert cf == 0, f"appendix control check FAIL count={cf}"
    print("  PASS")


def stats_noisefree():
    print("== Stats: noise-free +/-40 (fast must stay active, fallback=0) ==")
    rng = random.Random(11)
    # 无噪声 +/-40 时 Fast 路径必须仍然生效（fallback=0），
    # 周期应等于当前 Fast-SSC 基线（远低于流水 SC 的 5633/26625）。
    for n_log, expect_cyc in ((8, 1037), (10, 4239)):
        n = 1 << n_log
        k = n // 2
        frozen = make_frozen_mask(n_log, k)
        u = [0] * n
        for i in range(n):
            if not frozen[i]:
                u[i] = rng.getrandbits(1)
        from sc_model import polar_encode
        d = polar_encode(u, n_log)
        llrs = [40 if b == 0 else -40 for b in d]
        uf, up, fb, fc, pc = run_pair(n_log, frozen, llrs)
        assert uf == up and fb == 0, f"N={n} noise-free fallback={fb}"
        # 周期应与原 Fast-SSC 基线一致（说明 fast 路径仍然生效）
        assert fc == expect_cyc, f"N={n} fast cycles changed {fc} != {expect_cyc}"
        print(f"  N={n}: fast_cyc={fc} pipe_cyc={pc} fallback={fb} (fast active)")
    print("  PASS")


def main():
    test1()
    test2()
    test3()
    stats_noisefree()
    test4()
    print("== ALL REGRESSION SUITES PASS ==")


if __name__ == "__main__":
    main()
