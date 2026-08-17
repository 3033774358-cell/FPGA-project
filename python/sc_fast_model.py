# -*- coding: utf-8 -*-
"""
Cycle-accurate model of the Fast-SSC decoder built on top of the pipelined
line/stream SC decoder (sc_model.py).

Fast-SSC v1 features (bit-exact with SC):
  - Rate-0 subtree skip      : an all-frozen subtree is never visited; its
                               beta is treated as zero by the parent
                               (g with beta=0, merge copies/zeros).
  - Rate-1 vector decode     : a subtree whose bits are all information is
                               decoded in one pass with P lanes:
                                 DECIDE    : sign(alpha) -> uhat + raw beta
                                 TRANSFORM : beta = uhat * F^(xor len_log)
                               in place with P-lane butterfly passes.
  - u_hat output masks frozen positions to 0 (so Rate-0 subtrees never
    need u_hat writes).

Node types are precomputed bottom-up from the frozen mask (mirrors the RTL
fast-node type ROM filled at configuration time).

The controller mirrors the pipelined SC controller plus:
  - node type lookups at PH_F / PH_G entry;
  - skip transitions for Rate-0 children;
  - a fast-node sub-FSM (DECIDE / TRANSFORM chunks) with pipeline bubbles.
"""

from sc_model import (
    NMAX, MAX_LOG, INT_W, MEM_DEPTH,
    PH_F, PH_G, PH_C,
    ST_IDLE, ST_DECODE, ST_OUTPUT_START, ST_OUTPUT_WAIT,
    BETA_SRC_DIRECT, BETA_SRC_XOR, BETA_SRC_A, BETA_SRC_B,
    depth_base, sc_pe, polar_encode, make_frozen_mask,
    Decoder as PipeDecoder,
)

P = 8  # parallel lanes for fast nodes

R0 = 1
R1 = 2


def compute_types(frozen, n_log):
    """Bottom-up node types, heap indexed.
    heap_idx(depth, node_idx) = (1<<depth) - 1 + node_idx
    """
    n = 1 << n_log
    types = {}
    for depth in range(n_log, -1, -1):
        for idx in range(1 << depth):
            heap = (1 << depth) - 1 + idx
            if depth == n_log:
                types[heap] = R0 if frozen[idx] else R1
            else:
                t0 = types[2 * heap + 1]
                t1 = types[2 * heap + 2]
                if t0 == R0 and t1 == R0:
                    types[heap] = R0
                elif t0 == R1 and t1 == R1:
                    types[heap] = R1
                else:
                    types[heap] = 0  # normal
    return types


class FastController:
    def __init__(self, n_log, frozen_bits):
        self.n_log = n_log
        self.frozen_bits = frozen_bits
        self.types = compute_types(frozen_bits, n_log)
        self.reset()

    def reset(self):
        self.state = ST_IDLE
        self.decode_busy = 0
        self.decode_done = 0
        self.cur_depth = 0
        self.element_index = 0
        self.current_leaf = 0
        self.merge_second_write = 0
        self.phase = [PH_F] * (MAX_LOG + 1)
        self.bubble = 0
        self.heap = [0] * (MAX_LOG + 1)

        self.ph_checked = [0] * (MAX_LOG + 1)
        self.pg_checked = [0] * (MAX_LOG + 1)
        self.lmode = [0] * (MAX_LOG + 1)      # 0 normal, 1 R0-skip, 2 FAST
        self.rmode = [0] * (MAX_LOG + 1)
        self.merge_mode = [0] * (MAX_LOG + 1) # 0 normal, 1 left-R0, 2 right-R0

        # fast node sub-FSM
        self.fd_state = 0        # 0 none, 1 DECIDE, 2 TRANSFORM
        self.fd_chunk = 0
        self.fd_pass = 0
        self.fd_len_log = 0
        self.fd_base = 0
        self.fd_first_leaf = 0
        self.fd_gap = 0
        self.fd_zero_seen = 0
        self.fallback_count = 0

        self.o = {}
        self.reset_outputs()
        self.decode_start = 0

    def reset_outputs(self):
        self.o = dict(
            llr_a=0, llr_b=0, mode_g=0, wr_en=0, wr_addr=0,
            beta_ra=0, beta_rb=0, beta_wr_en=0, beta_wr_addr=0,
            beta_wr_data=0, beta_wr_mode=0,
            leaf_en=0, leaf_frozen=0, leaf_idx=0, leaf_beta_addr=0,
            output_start=0,
            beta_force0=0,
            fast_op=0, fast_chunk=0, fast_pass=0,
            fast_base=0, fast_uhat_base=0, fast_len_log=0,
        )

    # ------------------------------------------------------------------
    def comb(self):
        self.reset_outputs()
        n_log = self.n_log
        d = self.cur_depth
        elem = self.element_index

        if d <= n_log:
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

        in_decode = self.state == ST_DECODE

        if in_decode and self.fd_state != 0 and self.fd_gap == 0 and not self.bubble:
            # fast chunk issue
            self.o['fast_op'] = self.fd_state
            self.o['fast_chunk'] = self.fd_chunk
            self.o['fast_pass'] = self.fd_pass
            self.o['fast_base'] = self.fd_base
            self.o['fast_uhat_base'] = self.fd_first_leaf
            self.o['fast_len_log'] = self.fd_len_log
        elif in_decode and not self.bubble:
            if d == n_log:
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
                if not self.ph_checked[d]:
                    # entry check: R0 child -> no f op issued this cycle
                    t = self.types[2 * self.heap[d] + 1]
                    if t != R0:
                        self.o['llr_a'] = parent_a
                        self.o['llr_b'] = parent_b
                        self.o['mode_g'] = 0
                        self.o['wr_en'] = 1
                        self.o['wr_addr'] = child_addr
                else:
                    self.o['llr_a'] = parent_a
                    self.o['llr_b'] = parent_b
                    self.o['mode_g'] = 0
                    self.o['wr_en'] = 1
                    self.o['wr_addr'] = child_addr
            elif self.phase[d] == PH_G:
                if not self.pg_checked[d]:
                    t = self.types[2 * self.heap[d] + 2]
                    if t != R0:
                        self.o['llr_a'] = parent_a
                        self.o['llr_b'] = parent_b
                        self.o['mode_g'] = 1
                        self.o['wr_en'] = 1
                        self.o['wr_addr'] = child_addr
                        if self.lmode[d] != R0:
                            self.o['beta_ra'] = beta_child
                            self.o['beta_rb'] = beta_child
                            self.o['beta_wr_en'] = 1
                            self.o['beta_wr_addr'] = beta_pl
                            self.o['beta_wr_mode'] = BETA_SRC_A
                            self.o['beta_force0'] = 0
                        else:
                            self.o['beta_force0'] = 1
                    else:
                        self.o['beta_force0'] = 0
                else:
                    self.o['llr_a'] = parent_a
                    self.o['llr_b'] = parent_b
                    self.o['mode_g'] = 1
                    self.o['wr_en'] = 1
                    self.o['wr_addr'] = child_addr
                    if self.lmode[d] != R0:
                        self.o['beta_ra'] = beta_child
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_pl
                        self.o['beta_wr_mode'] = BETA_SRC_A
                        self.o['beta_force0'] = 0
                    else:
                        self.o['beta_force0'] = 1
            else:  # PH_C
                mm = self.merge_mode[d]
                if not self.merge_second_write:
                    if mm == 1:   # left R0: parent[k] = beta_r
                        self.o['beta_ra'] = beta_child
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_pl
                        self.o['beta_wr_mode'] = BETA_SRC_A
                    elif mm == 2: # right R0: parent[k] = beta_l (child region)
                        self.o['beta_ra'] = beta_child
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_pl
                        self.o['beta_wr_mode'] = BETA_SRC_A
                    else:
                        self.o['beta_ra'] = beta_pl
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_pl
                        self.o['beta_wr_mode'] = BETA_SRC_XOR
                else:
                    if mm == 1:   # parent[k+half] = beta_r
                        self.o['beta_ra'] = beta_child
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_ph
                        self.o['beta_wr_mode'] = BETA_SRC_A
                    elif mm == 2: # parent[k+half] = 0
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_ph
                        self.o['beta_wr_data'] = 0
                        self.o['beta_wr_mode'] = BETA_SRC_DIRECT
                    else:
                        self.o['beta_ra'] = beta_child
                        self.o['beta_rb'] = beta_child
                        self.o['beta_wr_en'] = 1
                        self.o['beta_wr_addr'] = beta_ph
                        self.o['beta_wr_mode'] = BETA_SRC_A

        if self.state == ST_OUTPUT_START:
            self.o['output_start'] = 1

    # ------------------------------------------------------------------
    def start_fast(self, depth):
        self.fd_state = 1  # DECIDE
        self.fd_chunk = 0
        self.fd_pass = 0
        self.fd_len_log = self.n_log - depth
        self.fd_base = depth_base(depth)
        self.fd_first_leaf = self.current_leaf
        self.fd_gap = 0
        self.fd_zero_seen = 0

    def finish_fast(self):
        L = 1 << self.fd_len_log
        self.current_leaf += L
        self.fd_state = 0
        self.fd_zero_seen = 0
        if self.cur_depth == 0:
            self.state = ST_OUTPUT_START
        else:
            self.cur_depth -= 1
            self.bubble = 1

    def next(self, output_done, fast_zero_hit=0):
        self.decode_done = 0
        n_log = self.n_log

        if self.state == ST_IDLE:
            self.decode_busy = 0
            self.cur_depth = 0
            self.element_index = 0
            self.current_leaf = 0
            self.merge_second_write = 0
            self.bubble = 0
            self.heap = [0] * (MAX_LOG + 1)
            self.phase = [PH_F] * (MAX_LOG + 1)
            self.ph_checked = [0] * (MAX_LOG + 1)
            self.pg_checked = [0] * (MAX_LOG + 1)
            self.lmode = [0] * (MAX_LOG + 1)
            self.rmode = [0] * (MAX_LOG + 1)
            self.merge_mode = [0] * (MAX_LOG + 1)
            self.fd_state = 0
            self.fd_gap = 0
            self.fd_zero_seen = 0

            if self.decode_start and 1 <= n_log <= MAX_LOG:
                self.decode_busy = 1
                self.state = ST_DECODE
                root_t = self.types[0]
                if root_t == R0:
                    self.current_leaf = 1 << n_log
                    self.state = ST_OUTPUT_START
                elif root_t == R1:
                    self.start_fast(0)

        elif self.state == ST_DECODE:
            self.decode_busy = 1

            if self.bubble:
                self.bubble = 0
            elif self.fd_state != 0:
                if self.fd_gap > 0:
                    self.fd_gap -= 1
                    # Rate-1 零 LLR 回退判定（与 RTL 一致）：
                    # 只在 DECIDE -> 第一个 TRANSFORM 的 gap 周期检查。
                    # 其它 gap 时 fd_zero_seen 已清零、fast_zero_hit 为 0。
                    if self.fd_zero_seen or fast_zero_hit:
                        self.fd_state = 0
                        self.fd_chunk = 0
                        self.fd_pass = 0
                        self.fd_zero_seen = 0
                        self.fallback_count += 1
                    else:
                        self.fd_zero_seen = 0
                else:
                    nchunks = max(1, (1 << self.fd_len_log) // P)
                    if self.fd_state == 1:  # DECIDE
                        if fast_zero_hit:
                            self.fd_zero_seen = 1
                        if self.fd_chunk == nchunks - 1:
                            self.fd_state = 2
                            self.fd_chunk = 0
                            self.fd_pass = 0
                            self.fd_gap = 1
                        else:
                            self.fd_chunk += 1
                    elif self.fd_state == 2:  # TRANSFORM
                        if (self.fd_pass == self.fd_len_log - 1 and
                                self.fd_chunk == nchunks - 1):
                            self.finish_fast()
                        elif self.fd_chunk == nchunks - 1:
                            self.fd_chunk = 0
                            self.fd_pass += 1
                            self.fd_gap = 1
                        else:
                            self.fd_chunk += 1
            else:
                d = self.cur_depth
                half = (1 << (n_log - d - 1)) if d < n_log else 0
                child_len = 1 << (n_log - d - 1) if d < n_log else 1

                if d == n_log:
                    self.current_leaf += 1
                    self.element_index = 0
                    self.merge_second_write = 0
                    if d != 0:
                        self.cur_depth -= 1
                    self.bubble = 1

                elif self.phase[d] == PH_F:
                    self.merge_mode[d] = 0
                    if not self.ph_checked[d]:
                        t = self.types[2 * self.heap[d] + 1]
                        if t == R0:
                            # skip PH_F entirely
                            self.lmode[d] = 1  # left child R0
                            self.phase[d] = PH_G
                            self.merge_mode[d] = 1  # left R0
                            self.current_leaf += child_len
                            self.element_index = 0
                        else:
                            self.ph_checked[d] = 1
                            self.lmode[d] = (
                                2 if (t == R1 and child_len >= 2) else 0)
                            if half == 1:
                                # first f op is also the last one
                                self.phase[d] = PH_G
                                if d < MAX_LOG:
                                    self.phase[d + 1] = PH_F
                                self.element_index = 0
                                self.merge_second_write = 0
                                self.cur_depth = d + 1
                                self.heap[d + 1] = 2 * self.heap[d] + 1
                                self.ph_checked[d + 1] = 0
                                self.pg_checked[d + 1] = 0
                                self.bubble = 1
                                if self.lmode[d] == 2:
                                    self.start_fast(d + 1)
                            else:
                                self.element_index += 1
                    elif self.element_index == half - 1:
                        self.phase[d] = PH_G
                        if d < MAX_LOG:
                            self.phase[d + 1] = PH_F
                        self.element_index = 0
                        self.merge_second_write = 0
                        self.cur_depth = d + 1
                        self.heap[d + 1] = 2 * self.heap[d] + 1
                        self.ph_checked[d + 1] = 0
                        self.pg_checked[d + 1] = 0
                        self.bubble = 1
                        if self.lmode[d] == 2:
                            self.start_fast(d + 1)
                    else:
                        self.element_index += 1

                elif self.phase[d] == PH_G:
                    if not self.pg_checked[d]:
                        t = self.types[2 * self.heap[d] + 2]
                        if t == R0:
                            self.phase[d] = PH_C
                            self.merge_mode[d] = 2  # right R0
                            self.current_leaf += child_len
                            self.element_index = 0
                            self.merge_second_write = 0
                        else:
                            self.pg_checked[d] = 1
                            self.rmode[d] = (
                                2 if (t == R1 and child_len >= 2) else 0)
                            if half == 1:
                                self.phase[d] = PH_C
                                if d < MAX_LOG:
                                    self.phase[d + 1] = PH_F
                                self.element_index = 0
                                self.merge_second_write = 0
                                self.cur_depth = d + 1
                                self.heap[d + 1] = 2 * self.heap[d] + 2
                                self.ph_checked[d + 1] = 0
                                self.pg_checked[d + 1] = 0
                                self.bubble = 1
                                if self.rmode[d] == 2:
                                    self.start_fast(d + 1)
                            else:
                                self.element_index += 1
                    elif self.element_index == half - 1:
                        self.phase[d] = PH_C
                        if d < MAX_LOG:
                            self.phase[d + 1] = PH_F
                        self.element_index = 0
                        self.merge_second_write = 0
                        self.cur_depth = d + 1
                        self.heap[d + 1] = 2 * self.heap[d] + 2
                        self.ph_checked[d + 1] = 0
                        self.pg_checked[d + 1] = 0
                        self.bubble = 1
                        if self.rmode[d] == 2:
                            self.start_fast(d + 1)
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


class FastDatapath:
    def __init__(self, frozen_bits, P_lanes=8):
        self.frozen_bits = frozen_bits
        self.P = P_lanes
        self.llr_mem = [0] * MEM_DEPTH
        self.beta_mem = [0] * MEM_DEPTH
        self.uhat = [0] * NMAX

        self.d1 = None
        self.d1_prev = None
        self.d1_fast = None
        self.d1_fast_prev = None

        self.output_busy = 0
        self.output_done = 0
        self.active_n = 0
        self.output_index = 0
        self.u_ready = 1
        self.fast_zero_hit = 0

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

    def edge(self, ctrl):
        o = ctrl.o

        # ---------------- normal pipelined path (same as PipeDecoder) -------
        llr_a = self.llr_mem[o['llr_a']]
        llr_b = self.llr_mem[o['llr_b']]
        beta_a = self.beta_mem[o['beta_ra']]
        beta_b = self.beta_mem[o['beta_rb']]

        # g op beta input: forced to 0 when the left child is Rate-0
        beta_pe = 0 if o['beta_force0'] else beta_a

        self.d1 = dict(
            llr_a=llr_a, llr_b=llr_b, beta_a=beta_a, beta_b=beta_b,
            mode_g=o['mode_g'], beta_pe=beta_pe,
            wr_en=o['wr_en'], wr_addr=o['wr_addr'],
            beta_wr_en=o['beta_wr_en'], beta_wr_addr=o['beta_wr_addr'],
            beta_wr_data=o['beta_wr_data'], beta_wr_mode=o['beta_wr_mode'],
            leaf_en=o['leaf_en'], leaf_frozen=o['leaf_frozen'],
            leaf_idx=o['leaf_idx'], leaf_beta_addr=o['leaf_beta_addr'],
        )

        if self.d1_prev is not None:
            d = self.d1_prev
            pe_y = sc_pe(d['llr_a'], d['llr_b'], d['mode_g'], d['beta_pe'])
            sel = self.beta_select_comb(
                d['beta_wr_mode'], d['beta_wr_data'], d['beta_a'], d['beta_b'])
            leaf = self.leaf_decision_comb(d['llr_a'], d['leaf_frozen'])

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

        # ---------------- fast node path -------------------------------------
        if o['fast_op'] == 1:  # DECIDE issued this cycle
            addr = o['fast_base'] + o['fast_chunk'] * self.P
            vec = [self.llr_mem[addr + i] if addr + i < MEM_DEPTH else 0
                   for i in range(self.P)]
            self.d1_fast = dict(
                op=1, vec=vec,
                beta_addr=addr,
                off=o['fast_chunk'] * self.P,
                uhat_base=o['fast_uhat_base'] + o['fast_chunk'] * self.P,
                len_log=o['fast_len_log'],
            )
        elif o['fast_op'] == 2:  # TRANSFORM issued this cycle
            addr = o['fast_uhat_base'] + o['fast_chunk'] * self.P
            m = 1 << o['fast_pass']
            A = [self.uhat[addr + i] if addr + i < NMAX else 0
                 for i in range(self.P)]
            B = [self.uhat[addr + m + i] if addr + m + i < NMAX else 0
                 for i in range(self.P)]
            self.d1_fast = dict(
                op=2, A=A, B=B, addr=addr,
                chunk=o['fast_chunk'], pass_p=o['fast_pass'],
                len_log=o['fast_len_log'],
            )
        else:
            # 与 RTL 一致：无 fast 微操作时 pipeline 寄存器清零，
            # 避免残留 d1 持续提交旧 chunk。
            self.d1_fast = None

        if self.d1_fast_prev is not None:
            d = self.d1_fast_prev
            L = 1 << d['len_log']
            if d['op'] == 1:
                off = d['off']
                for i in range(self.P):
                    if off + i < L:
                        dec = 1 if d['vec'][i] < 0 else 0
                        self.beta_mem[d['beta_addr'] + i] = dec
                        self.uhat[d['uhat_base'] + i] = dec
            elif d['op'] == 2:  # TRANSFORM
                off = d['chunk'] * self.P
                for i in range(self.P):
                    if (off + i < L and
                            (((off + i) >> d['pass_p']) & 1) == 0):
                        self.uhat[d['addr'] + i] = d['A'][i] ^ d['B'][i]
        self.d1_fast_prev = self.d1_fast

        # fast_zero_hit：由当前 pipeline 捕获的数据（d1_fast_prev）组合产生，
        # 仅在 DECIDE 且有效 lane 内检测 LLR 严格等于 0。
        self.fast_zero_hit = 0
        d = self.d1_fast_prev
        if d is not None and d.get('op') == 1:
            L = 1 << d['len_log']
            off = d['off']
            for i in range(self.P):
                if off + i < L and d['vec'][i] == 0:
                    self.fast_zero_hit = 1
                    break

        # ---------------- uhat output module (with frozen masking) -----------
        self.output_done = 0
        if not self.output_busy:
            if o['output_start']:
                self.active_n = 1 << ctrl.n_log
                self.output_index = 0
                self.output_busy = 1
        else:
            if self.u_ready:
                if self.output_index == self.active_n - 1:
                    self.output_busy = 0
                    self.output_done = 1
                    self.output_index = 0
                else:
                    self.output_index += 1

        raw = self.uhat[self.output_index]
        self.u_bit = 0 if self.frozen_bits[self.output_index] else raw
        self.u_index = self.output_index
        self.u_last = self.output_busy and (
            self.output_index == self.active_n - 1)


class FastDecoder:
    def __init__(self, n_log, frozen_bits):
        self.n_log = n_log
        self.frozen_bits = frozen_bits
        self.ctrl = FastController(n_log, frozen_bits)
        self.dp = FastDatapath(frozen_bits)

        self.load_busy = 0
        self.load_done = 0
        self.load_count = 0
        self.active_n = 1 << n_log
        self.cycle_count = 0
        self.out_u = []

    def load(self, llrs):
        self.ctrl = FastController(self.n_log, self.frozen_bits)
        self.dp = FastDatapath(self.frozen_bits)
        self.load_busy = 0
        self.load_done = 0
        self.load_count = 0
        self.out_u = []
        self.cycle_count = 0

        n = 1 << self.n_log
        idx = 0
        self.load_start = 1
        while True:
            self.ctrl.comb()
            self.dp.edge(self.ctrl)
            self.cycle_count += 1
            self.load_done = 0
            if self.load_start and not self.load_busy:
                self.active_n = 1 << self.n_log
                self.load_count = 0
                self.load_busy = 1
            elif self.load_busy:
                if idx < n:
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
        self.ctrl.decode_start = self.load_done
        monitor = 0
        while True:
            if callable(u_ready):
                self.dp.u_ready = u_ready(monitor)
            else:
                self.dp.u_ready = u_ready
            # fast_zero_hit 在本周期有效：由上一拍 edge() 捕获的 pipeline 数据产生
            fzh = self.dp.fast_zero_hit
            self.ctrl.comb()
            self.dp.edge(self.ctrl)
            self.ctrl.next(self.dp.output_done, fzh)
            self.cycle_count += 1
            monitor += 1
            if self.dp.output_busy and not self.dp.u_ready:
                pass
            if self.dp.output_busy and self.dp.u_ready:
                if self.dp.u_index == len(self.out_u):
                    self.out_u.append(self.dp.u_bit)
            if self.ctrl.decode_done:
                break


def run_case_fast(n_log, k, pattern, seed=1, amp=40):
    n = 1 << n_log
    rng = __import__("random").Random(seed)
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

    pipe = PipeDecoder(True, n_log, frozen)
    pipe.load(llrs)
    pipe.run_decode()

    fast = FastDecoder(n_log, frozen)
    fast.load(llrs)
    fast.run_decode()

    ok_same = (fast.out_u == pipe.out_u)
    ok_ref = (fast.out_u == u)
    return ok_ref, ok_same, pipe.cycle_count, fast.cycle_count


def main():
    print("N, K, pattern | fast==pipe | fast==ref | pipe_cyc | fast_cyc | speedup")
    total = 0
    for n_log in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10):
        n = 1 << n_log
        for k in sorted({0, 1, n // 4, n // 2, (3 * n) // 4, max(1, n - 1), n}):
            for pattern in (1, 2, 3, 0):
                for seed in range(3):
                    ok_ref, ok_same, pc, fc = run_case_fast(
                        n_log, k, pattern,
                        seed=n_log * 1000 + k * 7 + pattern * 13 + seed)
                    speed = pc / fc if fc else 0
                    total += 1
                    if total % 40 == 1 or not (ok_ref and ok_same):
                        print(f"{n:5d}, {k:5d}, {pattern}      | {ok_same!s:9} | "
                              f"{ok_ref!s:8} | {pc:7d} | {fc:7d} | {speed:6.2f}x")
                    assert ok_ref and ok_same, f"FAIL N={n} K={k} pattern={pattern}"
    print(f"ALL {total} CASES PASS")

    # back-to-back blocks with backpressure
    import random
    print("back-to-back + backpressure smoke tests ...")
    for n_log in (8, 10):
        n = 1 << n_log
        k = n // 2
        frozen = make_frozen_mask(n_log, k)
        rng = random.Random(7)

        def rand_u():
            u = [0] * n
            for i in range(n):
                if not frozen[i]:
                    u[i] = rng.getrandbits(1)
            return u

        dec = FastDecoder(n_log, frozen)
        for blk in range(2):
            u = rand_u()
            d = polar_encode(u, n_log)
            llrs = [40 if b == 0 else -40 for b in d]
            dec.load(llrs)
            dec.run_decode(u_ready=lambda c: 0 if (c % 17 == 5) else 1)
            assert dec.out_u == u, f"fast block {blk} N={n} mismatch"
            print(f"  N={n} block {blk}: OK (cycles={dec.cycle_count})")
    print("SMOKE TESTS PASS")

    # ---- real 5G 38.212 mask (N=1024, K=512) --------------------------------
    print("5G mask (N=1024 K=512) benchmark ...")
    hexs = [
        0x00000000000000000000000000000001,
        0x0000000000000001000000070117177F,
        0x00000000000000170001011701173FFF,
        0x0001011F077F7FFF177F7FFF7FFFFFFF,
        0x00000000000101170001013F077F7FFF,
        0x0003077F177F7FFF17FFFFFFFFFFFFFF,
        0x011717FF1FFFFFFF7FFFFFFFFFFFFFFF,
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
    ]
    frozen5g = []
    for h in reversed(hexs):
        for b in range(128):
            frozen5g.append((h >> b) & 1)
    rng = random.Random(5)
    u5 = [0] * 1024
    for i in range(1024):
        if not frozen5g[i]:
            u5[i] = rng.getrandbits(1)
    d5 = polar_encode(u5, 10)
    llr5 = [40 if b == 0 else -40 for b in d5]

    pipe5 = PipeDecoder(True, 10, frozen5g)
    pipe5.load(llr5)
    pipe5.run_decode()
    fast5 = FastDecoder(10, frozen5g)
    fast5.load(llr5)
    fast5.run_decode()
    assert fast5.out_u == pipe5.out_u == u5
    print(f"  pipe={pipe5.cycle_count} fast={fast5.cycle_count} "
          f"speedup={pipe5.cycle_count / fast5.cycle_count:.2f}x")
    print("5G MASK BENCHMARK PASS")


if __name__ == "__main__":
    main()
