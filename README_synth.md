# 星闪 Polar SC 译码器 综合包 (附录H 符合性修正版, 2026-08-10)

## 综合顶层
**`sc_decode_stream`**(流式 I/O 封装,引脚≈65,普通综合即可,**无需 OOC**)。
内部:`sc_decode_chain`(解级联→逐块 SC 译码→解补零/CRC 校验→解分段)
+ `seg_schedule`(与编码器**同一份**分段规则)+ SC 核。

## 文件(14 个,见 filelist.f)
- `rtl_ours/` 集成层 4:`sc_decode_stream` / `sc_decode_chain` / `seg_schedule` / `sc_decode_block`
- `rtl_core/` SC 核 7(组员实现):`sc_pe` / `sc_llr_mem` / `sc_beta_mem` / `sc_uhat_mem` / `sc_datapath` / `controller` / `sc_decoder_core`
- `rtl_shared/` 与编码器共用 3:`polar_reliability_rom` / `frozen_gen` / `crc_gen`

## 本次相对旧版的改动(按附录H金标准修正)
1. `seg_schedule.v`(`SA_PAD`):类型2末块 **K=实际消息位、不补零** —— 与编码器
   `polar_encode_chain.v` 同步(编解码共享同一分段规则,必须一起改)。
2. `sc_decode_chain.v`:新增 **`S_PMRG` R=1 旁路** —— R=1(MCS8/12)码块无信道编码,
   直接对 K 个 LLR 硬判决取信息位、不做 SC,`off` 前进 K(非 N)。用 `cur_rate1` 隔离,
   **R<1 路径逐字未变**。
面积增量可忽略(比较器 + 一个状态)。

3. **修 Vivado DRC REQP-1839 / REQP-1840**(共 40 条 BRAM 地址告警):
   告警内容 = "BRAM 地址引脚由带**异步复位**的寄存器驱动" —— 异步复位瞬间地址不跟
   时钟对齐地突变,可能污染存储内容,且该路径默认不做时序分析。 三处修正:
   - `rtl_ours/sc_decode_stream.v`:写地址 `wcnt` 移出异步复位块,改为独立无复位块
     (原异步复位本就冗余 —— 每次装载前 `cfg_start` 已显式清零)。→ 消 REQP-1840。
   - `rtl_core/controller.v`:主 FSM 块 `always @(posedge clk or negedge rst_n)`
     → `always @(posedge clk)`(**同步复位**),其 `state`/`cur_depth` 经 datapath
     驱动 BRAM 写地址。→ 消 REQP-1839。
   - `rtl_core/sc_llr_mem.v`:装载 FSM 块同样改同步复位(`load_count`/`load_busy`
     参与合成写地址 `mem_wa`)。
   均为机械转换,行为差异仅"复位在下一时钟沿生效",自由运行时钟下等效;同步复位
   也是 Xilinx 对 FPGA 的推荐做法。 **BRAM 推断未受影响**(yosys 确认 `llr_mem`/
   `beta_mem` 仍为存储器原语;综合后仍应看到 RAMB36E1/RAMB18E1)。

4. **类型2 + R=1 整帧直通**(与编码器 `polar_encode_chain.v` 同步):`seg_schedule.v`
   的 `SA_INIT` 在 `r16==16`(MCS8/12)时直接吐**单个直通块描述符**(`Kblk=Kmsg=B`),
   **不进表20/24 查表** ——【表24】只有 R=5/8,3/4,7/8,**无 R=1 条目**,误入会得到
   K=0 的空块并使调度不终止。 对应附录H TV213/214/215(金标准 "P:B")。

## 验证状态(可对组员交代)
- **附录H 独立验证 39/39 PASS**:金标准码字 `txPyLdC` → 无噪 LLR → 本译码链 →
  零错还原 `txPyLd` 且 `all_crc_ok=1`(**外部标准盖章,非自环**)。
- 自环端到端 5/5、流式封装等价 5/5、SC 核闭环 2200 例、可变N 200 例 全 PASS。
- Verilator lint:集成层无 latch/告警;yosys `check` 0 problems、无 latch。
- 上一轮综合(修 REQP 前)已确认:**时序 0 failing endpoints**,存储器成功进 BRAM
  (报告出现 RAMB36E1 / RAMB18E1 原语)。本轮改动只动复位方式,不影响功能与面积。

## Vivado 综合
```
vivado -mode batch -source synth_normal.tcl      # 顶层 sc_decode_stream
```
**器件**:用 **xc7a100t**(63400 LUT)。曾误用 xc7a35t(20800)会报超 100%。
参考规模(旧版实测):Slice LUT 31316/63400=49%,Reg 19425=15%,**BRAM 3.5 tile**,
IOB 65=38%。本次改动增量可忽略。

## ★综合后必查
`report_utilization` 里 **Block RAM Tile 必须 > 0**。若为 0,说明核内存没推断成
BRAM(会导致 LUT/FF 暴涨),需检查 `sc_llr_mem`/`sc_beta_mem` 的写是否在**独立无复位**
的 always 块里、读是否为**同步读**。

## 驱动注意
- `crc_seed[23:0]`:与编码端一致,按每帧 crcSeed(附录H 32 位取低 24 位)填。
- `B`/`mcs`/`ftype2` 与编码端同参;LLR 经 `s_valid/s_llr[8]/s_last` 串行喂入
  (**约定:比特0→正 LLR,比特1→负 LLR**),还原消息经 `mo_valid/mo_bit/mo_last` 串出。

## ★综合警告说明(2026-08-11 补 XDC 前的报告)
上一轮译码综合出现 **1000 条 TIMING-17 严重警告 + 5 条 SYNTH-6**:
- **TIMING-17(1000 条,已修)**:"时序钟未到达寄存器时钟引脚"。 根因是**译码工程
  当时没有任何时钟约束**,Vivado 不知道电路要跑多快,于是把每个寄存器都算成"未被
  时序钟覆盖"(1000 是规则上限,实际更多);此时的 WNS/WHS **不具参考价值**。
  → 已补 `constraints/sc_decode_stream.xdc`(100MHz 起步),并在 `synth_normal.tcl`
  里 `read_xdc`。重综合后 TIMING-17 应清零,且时序摘要应显示
  "All user specified timing constraints are met"。
- **SYNTH-6(5 条,不需处理)**:"RAM block 没有合并输出寄存器,时序可能次优"。
  这是 **Fmax 优化建议,不是错误** —— 我们的 BRAM 用的是 1 拍同步读
  (`rd <= mem[addr]`),没有第二级流水寄存器可供 Vivado 吸收进 BRAM 的可选输出
  寄存器(DO_REG)。 要消除它得再加一拍读延迟,会牵动 `controller` 的读相位
  (`rd_ph`)与整条流水,**代价大于收益**;当前时序余量充足(0 failing endpoints),
  暂不处理。 若将来目标频率显著提高(如 245.76MHz)再考虑。

## ★第二份报告(Messages)的警告判读 + 修复
- **`[Timing 38-313]` 无时序约束 + `[Place 46-29]` "Timing had been disabled during
  Placer" + `[Power 33-232]` 无用户时钟(×2)** —— 三条指向同一根因:工程没有 XDC。
  ⚠️ **`Place 46-29` 尤其要注意:布局阶段的时序优化被整个关掉了**,也就是说那一轮
  implementation 跑完的**时序/功耗数字全部无效**,布局也没有按速度优化过。
  → 已补 `constraints/sc_decode_stream.xdc` 并在 tcl 里 `read_xdc`,重跑即可。
- **`[Synth 8-4767]` uhat_mem 退化成寄存器 + `[Synth 8-7137]` Set/reset 同优先级
  (已修)** —— 根因与之前 `sc_llr_mem`/`sc_beta_mem` 完全相同:**存储器写语句在
  异步复位块内**。 8-7137 是**真实风险**(仿真与综合行为可能不一致),不是风格告警。
  → 把 `uhat_mem` 的写移到独立无复位块(写使能 = 原来的 `!output_busy && wr_en`,
  语义不变)。 yosys 实测:**4123 cells → 32 cells,1024 个 `$dffe` → 1 个 `$mem_v2`**,
  即 1024 个触发器换成一块分布式 RAM(读口是异步读,故为 LUTRAM 而非 BRAM)。
- **`[Board 49-26]`/`[Project 1-5713]` 板卡库警告(94 条)** —— Vivado 板卡库里有些
  板子的器件没装,与本设计无关,**可忽略**。
- **`[Synth 8-7129]` wr_index[10] 无负载 / `[Synth 8-3917]` 端口被常量驱动** ——
  参数化产生的位宽富余(1024 项只需 10 位地址),**无害**。

## ★第三份报告(上一版包)的 Synth 8-7137 —— 已修
`[Synth 8-7137] Register llr_blk_reg in module sc_decode_chain has both Set and
reset with same priority [sc_decode_chain.v:59]`
- 根因同前几处:`llr_blk`(8192 位)待在带异步复位的 always 块内、但复位分支未给它
  赋值,Vivado 推断时 Set/reset 优先级无法确定 → **仿真与综合可能不一致**(真实风险)。
- → 已把 `llr_blk` 与 `pass_msg` 的写移到**独立无复位块**(`pass_msg` 的清零必须
  一并移入 —— 同一信号不能被两个 always 块驱动)。语义不变:清零条件
  `(st==S_GET && blk_valid)`,写入条件 `(st==S_LOAD)`;顺带省掉 1024 个触发器的
  复位布线。
- 其余两条:`[Synth 8-7129]` wr_index[10] 无负载、`[Synth 8-3917]` 端口被常量驱动,
  都是参数化产生的位宽富余,**无害**。

### 「写在异步复位块里」问题汇总(本轮全部清干净)
| 模块 | 对象 | 症状 |
|---|---|---|
| `sc_llr_mem` | 存储器写 | REQP-1839(BRAM 地址由异步复位寄存器驱动) |
| `sc_beta_mem` | 存储器写 | 同上 |
| `sc_uhat_mem` | 存储器写 | Synth 8-4767(退化成 1024 个触发器)+ 8-7137 |
| `sc_decode_chain` | `llr_blk`/`pass_msg` | Synth 8-7137 |
| `sc_decode_stream` | `wcnt` | REQP-1840 |
| `code_block_concat`(编码侧) | `blk`/`elen`/`last_r` | Synth 8-7137 |
→ 统一处理原则:**存储器与纯数据寄存器一律放独立无复位块;只有控制状态才需要复位。**
