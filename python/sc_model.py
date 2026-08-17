# -*- coding: utf-8 -*-
"""
Cycle-accurate Python model of the line/stream SC decoder RTL
(controller + datapath + llr/beta/uhat memories + sc_pe).

Two variants are implemented:
  - baseline  : original combinational read -> PE -> synchronous write
                (write commits 1 cycle after issue)
  - pipelined : one pipeline register between memory read and PE,
                write controls/data delayed by one cycle
                (write commits 2 cycles after issue; controller inserts
                 bubbles at descend / leaf-return boundaries)

Used to verify that the pipelined schedule produces exactly the same
decoded u_hat as the baseline, and that both match the reference
encoder (d = u * F^(xor n), no bit-reversal, LLR mapping d=0 -> +A,
d=1 -> -A).
"""

import random


# ---------------------------------------------------------------------------
# constants matching RTL parameters
# ---------------------------------------------------------------------------
NMAX    = 1024
MAX_LOG = 10
INT_W   = 10
MEM_DEPTH = 2 * NMAX - 1      # 2047

PH_F = 0
PH_G = 1
PH_C = 2

ST_IDLE         = 0
ST_DECODE       = 1
ST_OUTPUT_START = 2
ST_OUTPUT_WAIT  = 3

BETA_SRC_DIRECT = 0
BETA_SRC_XOR    = 1
BETA_SRC_A      = 2
BETA_SRC_B      = 3


def depth_base(d):
    if d <= 0:
        return 0
    return 2 * NMAX - (NMAX >> (d - 1))


def sc_pe(a, b, mode_g, beta):
    """Exact port of rtl/sc_pe.v (W = INT_W = 10)."""
    MAX_EXT = 2 ** (INT_W - 1) - 1          # +511
    MIN_EXT = -(2 ** (INT_W - 1))           # -512
    MAX_MAG = 2 ** (INT_W - 1) - 1          # 511
    MIN_MAG = 2 ** (INT_W - 1)              # 512
    MAX_OUT = MAX_EXT
    MIN_OUT = MIN_EXT

    if not mode_g:
        abs_a = abs(a)
        abs_b = abs(b)
        min_abs = min(abs_a, abs_b)
        f_negative = (a < 0) ^ (b < 0)
        if f_negative:
            if min_abs >= MIN_MAG:
                return MIN_OUT
            return -min_abs
        if min_abs > MAX_MAG:
            return MAX_OUT
        return min_abs
    else:
        g_ext = (b - a) if beta else (b + a)
        if g_ext > MAX_EXT:
            return MAX_OUT
        if g_ext < MIN_EXT:
            return MIN_OUT
        return g_ext


def polar_encode(u, n_log):
    """d = u * F^(xor n), no bit reversal (matches tb_256/tb_1024 task)."""
    work = list(u)
    m = 1
    N = 1 << n_log
    while m < N:
        for base in range(0, N, 2 * m):
            for j in range(m):
                work[base + j] = work[base + j] ^ work[base + j + m]
        m <<= 1
    return work


# ---------------------------------------------------------------------------
# controller
# ---------------------------------------------------------------------------
class Controller:
    def __init__(self, pipelined, n_log, frozen_bits):
        self.pipelined = pipelined
        self.n_log = n_log
        self.frozen_bits = frozen_bits

        self.state = ST_IDLE
        self.decode_busy = 0
        self.decode_done = 0
        self.cur_depth = 0
        self.element_index = 0
        self.current_leaf = 0
        self.merge_second_write = 0
        self.phase = [PH_F] * (MAX_LOG + 1)
        self.bubble = 0

        # combinational outputs of the current cycle
        self.o = {}
        self.reset_outputs()

    def reset_outputs(self):
        self.o = dict(
            llr_a=0, llr_b=0, mode_g=0, wr_en=0, wr_addr=0,
            beta_ra=0, beta_rb=0, beta_wr_en=0, beta_wr_addr=0,
            beta_wr_data=0, beta_wr_mode=0,
            leaf_en=0, leaf_frozen=0, leaf_idx=0, leaf_beta_addr=0,
            output_start=0,
        )

    def comb(self):
        """Evaluate controller combinational outputs for the current cycle."""
        self.reset_outputs()

        n_log = self.n_log
        d = self.cur_depth
        elem = self.element_index

        if d <= n_log:
            current_node_len = 1 << (n_log - d)
            current_half = (1 << (n_log - d - 1)) if d < n_log else 0
        else:
            current_half = 0

        parent_base = depth_base(d)
        child_base = depth_base(min(d + 1, MAX_LOG))
        leaf_base = depth_base(n_log)

        parent_a = parent_base + elem
        parent_b = parent_base + current_half + elem
        child_addr = child_base + elem
        beta_pl = parent_base + elem
        beta_ph = parent_base + current_half + elem
        beta_child = child_base + elem

        if self.state == ST_DECODE and not (self.pipelined and self.bubble):
            if d == n_log:
                # leaf decision
                self.o['llr_a'] = leaf_base
                self.o['llr_b'] = leaf_base
                self.o['leaf_en'] = 1
                self.o['leaf_idx'] = self.current_leaf
                self.o['leaf_beta_addr'] = leaf_base
                if self.current_leaf < NMAX:
                    self.o['leaf_frozen'] = self.frozen_bits[self.current_leaf]
                else:
                    self.o['leaf_frozen'] = 1
            elif self.phase[d] == PH_F:
                self.o['llr_a'] = parent_a
                self.o['llr_b'] = parent_b
                self.o['mode_g'] = 0
                self.o['wr_en'] = 1
                self.o['wr_addr'] = child_addr
            elif self.phase[d] == PH_G:
                self.o['llr_a'] = parent_a
                self.o['llr_b'] = parent_b
                self.o['mode_g'] = 1
                self.o['wr_en'] = 1
                self.o['wr_addr'] = child_addr
                self.o['beta_ra'] = beta_child
                self.o['beta_rb'] = beta_child
                self.o['beta_wr_en'] = 1
                self.o['beta_wr_addr'] = beta_pl
                self.o['beta_wr_mode'] = BETA_SRC_A
            else:  # PH_C
                if not self.merge_second_write:
                    self.o['beta_ra'] = beta_pl
                    self.o['beta_rb'] = beta_child
                    self.o['beta_wr_en'] = 1
                    self.o['beta_wr_addr'] = beta_pl
                    self.o['beta_wr_mode'] = BETA_SRC_XOR
                else:
                    self.o['beta_ra'] = beta_child
                    self.o['beta_rb'] = beta_child
                    self.o['beta_wr_en'] = 1
                    self.o['beta_wr_addr'] = beta_ph
                    self.o['beta_wr_mode'] = BETA_SRC_A

        if self.state == ST_OUTPUT_START:
            self.o['output_start'] = 1

    def next(self, output_done):
        """Advance controller registers on the clock edge."""
        self.decode_done = 0

        if self.state == ST_IDLE:
            self.decode_busy = 0
            self.cur_depth = 0
            self.element_index = 0
            self.current_leaf = 0
            self.merge_second_write = 0
            self.bubble = 0
            if (self.decode_start and
                    1 <= self.n_log <= MAX_LOG):
                self.decode_busy = 1
                self.cur_depth = 0
                self.element_index = 0
                self.current_leaf = 0
                self.merge_second_write = 0
                self.bubble = 0
                self.phase = [PH_F] * (MAX_LOG + 1)
                self.state = ST_DECODE

        elif self.state == ST_DECODE:
            self.decode_busy = 1

            if self.pipelined and self.bubble:
                self.bubble = 0
            else:
                d = self.cur_depth
                half = (1 << (self.n_log - d - 1)) if d < self.n_log else 0

                if d == self.n_log:
                    self.current_leaf += 1
                    self.element_index = 0
                    self.merge_second_write = 0
                    if d != 0:
                        self.cur_depth -= 1
                    if self.pipelined:
                        self.bubble = 1

                elif self.phase[d] == PH_F:
                    if self.element_index == half - 1:
                        self.phase[d] = PH_G
                        if d < MAX_LOG:
                            self.phase[d + 1] = PH_F
                        self.element_index = 0
                        self.merge_second_write = 0
                        self.cur_depth += 1
                        if self.pipelined:
                            self.bubble = 1
                    else:
                        self.element_index += 1

                elif self.phase[d] == PH_G:
                    if self.element_index == half - 1:
                        self.phase[d] = PH_C
                        if d < MAX_LOG:
                            self.phase[d + 1] = PH_F
                        self.element_index = 0
                        self.merge_second_write = 0
                        self.cur_depth += 1
                        if self.pipelined:
                            self.bubble = 1
                    else:
                        self.element_index += 1

                else:  # PH_C
                    if not self.merge_second_write:
                        self.merge_second_write = 1
                    else:
                        self.merge_second_write = 0
                        if self.element_index == half - 1:
                            self.element_index = 0
                            if d == 0:
                                self.state = ST_OUTPUT_START
                            else:
                                self.cur_depth -= 1
                        else:
                            self.element_index += 1

        elif self.state == ST_OUTPUT_START:
            self.decode_busy = 1
            self.state = ST_OUTPUT_WAIT

        elif self.state == ST_OUTPUT_WAIT:
            self.decode_busy = 1
            if output_done:
                self.decode_busy = 0
                self.decode_done = 1
                self.state = ST_IDLE


# ---------------------------------------------------------------------------
# memories / datapath
# ---------------------------------------------------------------------------
class Datapath:
    def __init__(self, pipelined):
        self.pipelined = pipelined
        self.llr_mem = [0] * MEM_DEPTH
        self.beta_mem = [0] * MEM_DEPTH
        self.uhat = [0] * NMAX

        # pipeline stage register (captured at edge after issue)
        self.d1 = None
        self.d1_prev = None

        # output module state (sc_uhat_mem)
        self.output_busy = 0
        self.output_done = 0
        self.active_n = 0
        self.output_index = 0

    # -- combinational helpers --------------------------------------------
    def leaf_decision_comb(self, llr_a, leaf_frozen):
        return 0 if leaf_frozen else (1 if llr_a < 0 else 0)

    def beta_select_comb(self, mode, wr_data, beta_a, beta_b):
        if mode == BETA_SRC_DIRECT:
            return wr_data
        if mode == BETA_SRC_XOR:
            return beta_a ^ beta_b
        if mode == BETA_SRC_A:
            return beta_a
        return beta_b

    # -- edge --------------------------------------------------------------
    def edge(self, ctrl):
        o = ctrl.o

        if not self.pipelined:
            # write at this edge using combinational values of this cycle
            llr_a = self.llr_mem[o['llr_a']]
            llr_b = self.llr_mem[o['llr_b']]
            beta_a = self.beta_mem[o['beta_ra']]
            beta_b = self.beta_mem[o['beta_rb']]
            pe_y = sc_pe(llr_a, llr_b, o['mode_g'], beta_a)
            sel = self.beta_select_comb(
                o['beta_wr_mode'], o['beta_wr_data'], beta_a, beta_b)
            leaf = self.leaf_decision_comb(llr_a, o['leaf_frozen'])

            if o['wr_en']:
                self.llr_mem[o['wr_addr']] = pe_y

            beta_wr_en = o['leaf_en'] | o['beta_wr_en']
            if beta_wr_en:
                self.beta_mem[
                    o['leaf_beta_addr'] if o['leaf_en'] else o['beta_wr_addr']
                ] = leaf if o['leaf_en'] else sel

            if o['leaf_en']:
                self.uhat[o['leaf_idx']] = leaf

            self.d1 = None
        else:
            # ---- pipelined ------------------------------------------------
            # stage A combinational: memory reads of this cycle
            llr_a = self.llr_mem[o['llr_a']]
            llr_b = self.llr_mem[o['llr_b']]
            beta_a = self.beta_mem[o['beta_ra']]
            beta_b = self.beta_mem[o['beta_rb']]

            # capture stage A -> d1 at this edge
            self.d1 = dict(
                llr_a=llr_a, llr_b=llr_b, beta_a=beta_a, beta_b=beta_b,
                mode_g=o['mode_g'],
                wr_en=o['wr_en'], wr_addr=o['wr_addr'],
                beta_wr_en=o['beta_wr_en'], beta_wr_addr=o['beta_wr_addr'],
                beta_wr_data=o['beta_wr_data'], beta_wr_mode=o['beta_wr_mode'],
                leaf_en=o['leaf_en'], leaf_frozen=o['leaf_frozen'],
                leaf_idx=o['leaf_idx'], leaf_beta_addr=o['leaf_beta_addr'],
            )

            # stage B combinational evaluated from d1 (registered one edge ago)
            if self.d1_prev is not None:
                d = self.d1_prev
                pe_y = sc_pe(d['llr_a'], d['llr_b'], d['mode_g'], d['beta_a'])
                sel = self.beta_select_comb(
                    d['beta_wr_mode'], d['beta_wr_data'],
                    d['beta_a'], d['beta_b'])
                leaf = self.leaf_decision_comb(d['llr_a'], d['leaf_frozen'])

                # write at this edge with d1 (one-edge-old) data/controls
                if d['wr_en']:
                    self.llr_mem[d['wr_addr']] = pe_y

                beta_wr_en = d['leaf_en'] | d['beta_wr_en']
                if beta_wr_en:
                    self.beta_mem[
                        d['leaf_beta_addr'] if d['leaf_en'] else d['beta_wr_addr']
                    ] = leaf if d['leaf_en'] else sel

                if d['leaf_en']:
                    self.uhat[d['leaf_idx']] = leaf

            self.d1_prev = self.d1

        # ---- uhat output module (sc_uhat_mem) -----------------------------
        self.output_done = 0
        if not self.output_busy:
            if o['leaf_en']:
                pass  # write already handled above
            if o['output_start']:
                self.active_n = 1 << ctrl.n_log
                self.output_index = 0
                self.output_busy = 1
        else:
            if self.output_busy and self.u_ready:
                if self.output_index == self.active_n - 1:
                    self.output_busy = 0
                    self.output_done = 1
                    self.output_index = 0
                else:
                    self.output_index += 1

        self.u_bit = self.uhat[self.output_index]
        self.u_index = self.output_index
        self.u_last = self.output_busy and (self.output_index == self.active_n - 1)


# ---------------------------------------------------------------------------
# full decoder driver
# ---------------------------------------------------------------------------
class Decoder:
    def __init__(self, pipelined, n_log, frozen_bits):
        self.pipelined = pipelined
        self.n_log = n_log
        self.frozen_bits = frozen_bits
        self.ctrl = Controller(pipelined, n_log, frozen_bits)
        self.dp = Datapath(pipelined)

        # load state
        self.load_busy = 0
        self.load_done = 0
        self.load_count = 0
        self.active_n = 1 << n_log

        self.cycle_count = 0
        self.out_u = []
        self.finished = False
        self.dp.d1 = None
        self.dp.d1_prev = None

    def reset(self):
        self.ctrl = Controller(self.pipelined, self.n_log, self.frozen_bits)
        self.dp = Datapath(self.pipelined)
        self.load_busy = 0
        self.load_done = 0
        self.load_count = 0
        self.out_u = []
        self.finished = False
        self.cycle_count = 0

    def load(self, llrs):
        """Run load phase: llr_in_valid for N cycles (like tb)."""
        self.reset()
        n = 1 << self.n_log
        idx = 0
        self.load_start = 1
        # cycle 0: assert load_start
        while True:
            # controller comb (idle) + datapath edge
            self.ctrl.comb()
            self.dp.edge(self.ctrl)
            self.cycle_count += 1
            # load FSM edge (sc_llr_mem)
            self.load_done = 0
            if self.load_start and not self.load_busy:
                self.active_n = 1 << self.n_log
                self.load_count = 0
                self.load_busy = 1
            elif self.load_busy:
                if idx < n and self.load_busy:
                    self.dp.llr_mem[self.load_count] = llrs[idx]
                    idx += 1
                    if self.load_count == self.active_n - 1:
                        self.load_count = 0
                        self.load_busy = 0
                        self.load_done = 1
                        self.ctrl.decode_start = 1
                    else:
                        self.load_count += 1
            self.load_start = 0
            if self.load_done:
                break

    def run_decode(self, u_ready=True):
        """Run until decode_done; collect u output."""
        self.ctrl.decode_start = self.load_done  # stays 1 only during load_done
        monitor_cycle = 0
        while True:
            if callable(u_ready):
                self.dp.u_ready = u_ready(monitor_cycle)
            else:
                self.dp.u_ready = u_ready
            self.ctrl.comb()
            self.dp.edge(self.ctrl)
            self.ctrl.next(self.dp.output_done)
            self.cycle_count += 1
            monitor_cycle += 1

            if self.dp.output_busy and u_ready:
                if self.dp.u_last:
                    pass
            # collect output samples
            if self.dp.output_busy:
                if self.dp.u_index == len(self.out_u):
                    self.out_u.append(self.dp.u_bit)

            if self.ctrl.decode_done:
                self.finished = True
                break


# ---------------------------------------------------------------------------
# test harness
# ---------------------------------------------------------------------------
def make_frozen_mask(n_log, k):
    """Frozen mask used by the model (frozen = first N-K indices)."""
    n = 1 << n_log
    return [1 if i < (n - k) else 0 for i in range(n)]


def run_case(n_log, k, pattern, seed=1, amp=40):
    """Run baseline and pipelined models on one code block."""
    n = 1 << n_log
    rng = random.Random(seed)
    frozen = make_frozen_mask(n_log, k)

    u = [0] * n
    for i in range(n):
        if not frozen[i]:
            if pattern == 1:
                u[i] = i % 2
            elif pattern == 2:
                u[i] = 1
            elif pattern == 3:
                u[i] = 1 if (((i * 13 + 7) % 5) < 2) else 0
            else:
                u[i] = rng.getrandbits(1)

    d = polar_encode(u, n_log)
    llrs = [amp if bit == 0 else -amp for bit in d]

    results = {}
    for pipelined in (False, True):
        dec = Decoder(pipelined, n_log, frozen)
        dec.load(llrs)
        start_cycle = dec.cycle_count
        dec.run_decode()
        results[pipelined] = (dec.out_u, dec.cycle_count)

    base_uhat, base_cycles = results[False]
    pipe_uhat, pipe_cycles = results[True]

    ok_ref = (base_uhat == u)
    ok_same = (base_uhat == pipe_uhat)
    return ok_ref, ok_same, base_cycles, pipe_cycles


def main():
    print("N, K, pattern | ref_match | pipe==base | base_cyc | pipe_cyc | extra%")
    total = 0
    for n_log in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10):
        n = 1 << n_log
        for k in sorted({1, n // 4, n // 2, (3 * n) // 4, max(1, n - 1), n}):
            for pattern in (1, 2, 3, 0):
                for seed in range(3):
                    ok_ref, ok_same, bc, pc = run_case(
                        n_log, k, pattern, seed=n_log * 1000 + k * 7 + pattern * 13 + seed)
                    extra = 100.0 * (pc - bc) / bc
                    total += 1
                    if total % 40 == 1 or not (ok_ref and ok_same):
                        print(f"{n:5d}, {k:5d}, {pattern}      | {ok_ref!s:9} | "
                              f"{ok_same!s:10} | {bc:7d} | {pc:7d} | {extra:6.1f}%")
                    assert ok_ref and ok_same, f"FAIL at N={n} K={k} pattern={pattern} seed={seed}"
    print(f"ALL {total} CASES PASS")

    # ---- back-to-back blocks + backpressure smoke tests -------------------
    print("back-to-back + backpressure smoke tests ...")
    n_log = 8
    n = 1 << n_log
    k = n // 2
    frozen = make_frozen_mask(n_log, k)
    rng = random.Random(42)

    def random_u():
        u = [0] * n
        for i in range(n):
            if not frozen[i]:
                u[i] = rng.getrandbits(1)
        return u

    for pipelined in (False, True):
        dec = Decoder(pipelined, n_log, frozen)
        for blk in range(2):
            u = random_u()
            d = polar_encode(u, n_log)
            llrs = [40 if bit == 0 else -40 for bit in d]
            dec.load(llrs)
            # backpressure: u_ready low on a periodic pattern
            ready_state = {"cycle": 0}

            def u_ready_fn(c):
                return 0 if (c % 17 == 5 or c % 23 == 11) else 1

            dec.run_decode(u_ready=u_ready_fn)
            assert dec.out_u == u, f"block {blk} mismatch in pipelined={pipelined}"
            print(f"  pipelined={pipelined} block {blk}: OK (cycles={dec.cycle_count})")
    print("SMOKE TESTS PASS")


if __name__ == "__main__":
    main()
