# -*- coding: utf-8 -*-
"""
Appendix H (T/XS 10002-2025) payload TV check for the Fast-SSC decoder.

Flow (mirrors tb_tv_decoder_sc.sv):
  1. per TV: read cfg (FT/MCS/B/CRC_SEED/CRC_LEN) and tv_vectors
     (in.memh = txPyLd expected message, exp.memh = txPyLdC encoded bits);
  2. block schedule (N:K, kmsg, pad, vbase, shared) from the same
     polar_block_scheduler rules as the RTL;
  3. per block: frozen mask via frozen_gen rules + project Q ROM,
     LLR = bit0->+64 / bit1->-64, decode with the Fast-SSC model;
  4. extract info bits V per block, reassemble the message,
     compare with txPyLd bit-by-bit.
"""

import os
import re
import sys
from math import ceil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from sc_fast_model import FastDecoder
from sc_model import Decoder as PipeDecoder

HERE = os.path.dirname(os.path.abspath(__file__))

# 可靠性 ROM 与脚本同目录（工程交付包内）。
# 测试向量目录：默认 HERE/tv_vectors，可用环境变量 TVROOT 覆盖；
# 若不存在则整项 SKIP，不使 regression 失败。
Q_ROM = os.path.join(HERE, "polar_reliability_rom.v")
TVROOT = os.environ.get("TVROOT", os.path.join(HERE, "tv_vectors"))
APPENDIX_H_JSON = os.environ.get(
    "APPENDIX_H_JSON",
    os.path.join(HERE, "appendix_H_tvs.json"),
)


def tv_vectors_available():
    return os.path.isdir(TVROOT) and any(
        f.startswith("TV") and f.endswith(".cfg")
        for f in os.listdir(TVROOT)
    )


def appendix_json_available():
    return os.path.isfile(APPENDIX_H_JSON)

MCS_R16 = {0: 4, 1: 6, 2: 4, 3: 6, 4: 8, 5: 10, 6: 12, 7: 14, 8: 16,
           9: 10, 10: 12, 11: 14, 12: 16}
TAB20 = {
    0: (0, 0, 0), 1: (0, 0, 1), 2: (0, 0, 2), 3: (0, 1, 1), 4: (0, 1, 2),
    5: (0, 2, 1), 6: (0, 2, 2), 7: (1, 1, 1), 8: (1, 1, 2), 9: (1, 2, 1),
    10: (1, 2, 2), 11: (2, 1, 1), 12: (2, 1, 2), 13: (2, 2, 1), 14: (2, 2, 2),
}
TAB24 = {10: (316, 156, 74, 36), 12: (382, 189, 90, 45), 14: (446, 221, 106, 53)}
TAB23 = {
    4: (96, 48, 24, 12), 6: (160, 80, 40, 20), 8: (224, 112, 56, 28),
    10: (288, 144, 72, 36), 12: (352, 176, 88, 44), 14: (416, 208, 104, 52),
}

# 与 tb_tv_decoder_sc.sv 相同的 38 条载荷 TV
TVS = [
    (201, 2, 32, 7, 0x123456), (202, 2, 560, 7, 0x123456),
    (203, 2, 568, 9, 0x123456), (204, 2, 1928, 9, 0x123456),
    (205, 2, 32, 6, 0x123456), (206, 2, 1440, 6, 0x123456),
    (207, 2, 1448, 10, 0x123456), (208, 2, 2064, 10, 0x123456),
    (209, 2, 32, 11, 0x555555), (210, 2, 1680, 11, 0x555555),
    (211, 2, 1688, 11, 0x555555), (212, 2, 2064, 11, 0x555555),
    (301, 3, 800, 6, 0x555555), (302, 3, 1424, 6, 0x555555),
    (303, 3, 1432, 10, 0x123456), (304, 3, 1536, 10, 0x12345678),
    (305, 3, 928, 7, 0x555555), (306, 3, 1672, 7, 0x555555),
    (307, 3, 1680, 11, 0x123456), (308, 3, 1792, 11, 0x12345678),
    (309, 3, 1168, 9, 0x123456), (310, 3, 1192, 9, 0x123456),
    (401, 4, 288, 0, 0x567891), (402, 4, 432, 0, 0x567891),
    (403, 4, 440, 2, 0x56789178), (404, 4, 448, 2, 0x56789178),
    (405, 4, 416, 1, 0x555555), (406, 4, 680, 1, 0x555555),
    (407, 4, 688, 3, 0x56789178), (408, 4, 768, 3, 0x555555),
    (409, 4, 544, 4, 0x567891), (410, 4, 928, 4, 0x567891),
    (411, 4, 936, 4, 0x555555), (412, 4, 1024, 4, 0x567891),
    (413, 4, 672, 5, 0x567891), (414, 4, 1176, 5, 0x567891),
    (415, 4, 1184, 5, 0x567891), (416, 4, 1280, 5, 0x555555),
]


def load_q_rom(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    mem = {}
    for m in re.finditer(r"mem\[(\d+)\]=\d+'d(\d+);", src):
        mem[int(m.group(1))] = int(m.group(2))
    assert len(mem) == 1024, len(mem)
    return [mem[i] for i in range(1024)]


Q_SEQ = load_q_rom(Q_ROM)


def frozen_gen_mask(n_log, K):
    """Port of frozen_gen.v: mark the K most-reliable (q<N) positions info."""
    N = 1 << n_log
    frozen = [1] * N
    need = K
    for rank in range(1023, -1, -1):
        if need == 0:
            break
        q = Q_SEQ[rank]
        if q < N:
            frozen[q] = 0
            need -= 1
    assert need == 0
    return frozen


def schedule(B, ft, r16):
    """Same block schedule as polar_block_scheduler.v (validated by
    validate_blocks.py against appendix-H BLOCKS)."""
    blocks = []
    if ft == 2:
        K1024 = 1024 * r16 // 16
        thr = 1920 * r16 // 16
        if B > thr:
            n1024 = (B - 904 * r16 // 16) // K1024
            km = B - n1024 * K1024
        else:
            n1024 = 0
            km = B
        idx = min((km - 1) // (128 * r16 // 16), 14)
        n512, n256, n128 = TAB20[idx]
        k512, k256, k128, k64 = TAB24[r16]
        rem = km - n512 * k512 - n256 * k256 - n128 * k128
        n64 = ceil(rem / k64) if rem > 0 else 0
        blk = [1024] * n1024 + [512] * n512 + [256] * n256 + [128] * n128 + [64] * n64
        Ks = {1024: K1024, 512: k512, 256: k256, 128: k128, 64: k64}
        pos = 0
        for bi, N in enumerate(blk):
            K = (B - pos) if bi == len(blk) - 1 else Ks[N]
            blocks.append((N.bit_length() - 1, K, K, 0, 0, 0, 0))
            pos += K
    else:
        Kcb = 1024 * r16 // 16
        if B <= Kcb:
            C, L = 1, 0
            Kr = B
            full = []
        else:
            L = 24
            C = ceil(B / (Kcb - L))
            Kr = B - (C - 1) * (Kcb - L) + L
            full = [(10, Kcb, Kcb - 24, 0, 1, 0, 0)] * (C - 1)
        blocks.extend(full)
        kmsg_last = (Kr - L) if L else Kr
        U = 4 * (r16 - 1)
        if Kr > 16 * U:
            sub = [(10, Kcb, kmsg_last, Kcb - Kr, 1 if L else 0, 0, 1)]
        elif ceil(Kr / U) == 16:
            sub = [(10, 16 * U, kmsg_last, 16 * U - Kr, 1 if L else 0, 0, 1)]
        else:
            q = ceil(Kr / U)
            sel = [q >> 3 & 1, q >> 2 & 1, q >> 1 & 1, q & 1]
            pad0 = q * U - Kr
            vbase = 0
            sub = []
            for use, N, K in zip(sel, (512, 256, 128, 64), TAB23[r16]):
                if use:
                    sub.append((N.bit_length() - 1, K, kmsg_last,
                                pad0, 1 if L else 0,
                                vbase, 1))
                    vbase += K
        blocks.extend(sub)
    return blocks


def read_memh(path):
    """Read 32-bit hex words, LSB-first bit stream."""
    bits = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        w = int(line, 16)
        for b in range(32):
            bits.append((w >> b) & 1)
    return bits


def read_cfg(tv_id):
    cfg = {}
    for line in open(os.path.join(TVROOT, f"TV{tv_id}.cfg"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        k, _, v = line.partition(" ")
        cfg[k.strip()] = v.strip()
    return cfg


def decode_block(n_log, K, llrs, use_fast=True):
    frozen = frozen_gen_mask(n_log, K)
    if use_fast:
        dec = FastDecoder(n_log, frozen)
    else:
        dec = PipeDecoder(True, n_log, frozen)
    dec.load(llrs)
    dec.run_decode()
    return dec.out_u, dec.cycle_count


def run_tv(tv_id, ft, B, mcs, use_fast=True, verbose=False):
    cfg = read_cfg(tv_id)
    exp_bits = read_memh(os.path.join(TVROOT, f"TV{tv_id}.exp.memh"))
    in_bits = read_memh(os.path.join(TVROOT, f"TV{tv_id}.in.memh"))

    blocks = schedule(B, ft, MCS_R16[mcs])

    cfg_blocks = cfg.get("BLOCKS", "").split()
    sched_str = " ".join(f"{1 << n}:{K}" for (n, K, *_rest) in blocks)
    if cfg_blocks and " ".join(cfg_blocks) != sched_str:
        print(f"  [WARN] TV{tv_id} schedule mismatch: cfg={cfg_blocks} sched={sched_str}")

    msg = []
    pos = 0
    total_cyc = 0
    blk_detail = []
    for (nlog, K, kmsg, pad, crc_on, vbase, is_shared) in blocks:
        N = 1 << nlog
        llrs = [64 if b == 0 else -64 for b in exp_bits[pos:pos + N]]
        uhat, cyc = decode_block(nlog, K, llrs, use_fast)
        total_cyc += cyc
        frozen = frozen_gen_mask(nlog, K)
        V = [uhat[j] for j in range(N) if not frozen[j]]
        assert len(V) == K
        if not is_shared:
            msg += V[:kmsg]
        else:
            for j in range(K):
                if pad <= vbase + j < pad + kmsg:
                    msg.append(V[j])
        blk_detail.append((N, K))
        pos += N

    exp = in_bits[:B]
    ok = (msg == exp)
    if verbose or not ok:
        first_bad = next((i for i, (a, b) in enumerate(zip(msg, exp)) if a != b), None)
        print(f"  TV{tv_id} FT{ft} B={B} mcs={mcs} blocks={blk_detail} "
              f"msg={len(msg)} {'PASS' if ok else 'FAIL'}"
              + (f" mismatch@{first_bad}" if first_bad is not None else "")
              + f" cycles={total_cyc}")
    return ok, total_cyc


def main():
    print("== Appendix H payload check: Fast-SSC decoder ==")
    if not tv_vectors_available():
        print("[SKIP] Appendix-H TV vectors not found (%s)" % TVROOT)
        return 0, 0
    pass_n = fail_n = 0
    cyc_sum = 0
    for tv_id, ft, B, mcs, _crc in TVS:
        ok, cyc = run_tv(tv_id, ft, B, mcs, use_fast=True, verbose=True)
        pass_n += ok
        fail_n += (not ok)
        cyc_sum += cyc
    print(f"== result: {pass_n} pass, {fail_n} fail (total cycles={cyc_sum}) ==")

    print("cross-check Fast-SSC vs pipelined SC on TV202 ...")
    exp_bits = read_memh(os.path.join(TVROOT, "TV202.exp.memh"))
    for (nlog, K, *_rest) in schedule(560, 2, 14):
        N = 1 << nlog
        llrs = [64 if b == 0 else -64 for b in exp_bits[:N]]
        uf, _ = decode_block(nlog, K, llrs, use_fast=True)
        up, _ = decode_block(nlog, K, llrs, use_fast=False)
        assert uf == up, f"TV202 block N={N} K={K} mismatch"
        exp_bits = exp_bits[N:]
    print("cross-check PASS")
    return pass_n, fail_n


def check_control_tvs():
    """Control channel: decode txHeadC (N=64/K=48 for FT2, N=256/K=51 for
    FT3/4) and compare the info-bit extraction with txHead."""
    import json
    if not appendix_json_available():
        print("[SKIP] Appendix-H JSON not found (%s)" % APPENDIX_H_JSON)
        return 0, 0
    tvs = json.load(open(APPENDIX_H_JSON, encoding="utf-8"))
    pass_n = fail_n = 0
    print("== Appendix H control check: Fast-SSC decoder ==")
    for tv in tvs:
        ft = tv["frame_type"]
        if ft not in (2, 3, 4):
            continue
        tid = tv["tv_id"]
        fields = tv["fields"]
        if "txHeadC" not in fields or "txHead" not in fields:
            continue
        thead = fields["txHead"]["bits"]
        coded = fields["txHeadC"]["bits"]
        if ft == 2:
            n_log, K = 6, len(thead)      # N=64, K=48
        else:
            n_log, K = 8, len(thead)      # N=256, K=51
        N = 1 << n_log
        if len(coded) != N:
            continue
        llrs = [64 if b == 0 else -64 for b in coded]
        uhat, cyc = decode_block(n_log, K, llrs, use_fast=True)
        frozen = frozen_gen_mask(n_log, K)
        V = [uhat[j] for j in range(N) if not frozen[j]]
        ok = (V == thead)
        pass_n += ok
        fail_n += (not ok)
        print(f"  TV{tid} FT{ft} ctrl N={N} K={K} "
              f"{'PASS' if ok else 'FAIL'} cycles={cyc}")
    print(f"== control result: {pass_n} pass, {fail_n} fail ==")
    return pass_n, fail_n


if __name__ == "__main__":
    main()
    check_control_tvs()
