# 星闪 Polar 编码器 综合包 (附录H 符合性修正版, 2026-08-10)

## 综合顶层
**`polar_encode_stream`**(流式输入封装,引脚≈95,普通综合即可,**无需 OOC**)。
它原封实例化链核 `polar_encode_chain`(完整实现 T/XS 10002-2025 §6.9 编码链:
分段→CRC24B→极化编码→级联)。

## 文件(7 个,见 filelist.f,叶子在前)
```
rtl/polar_reliability_rom.v   附录C 可靠度序列 ROM
rtl/frozen_gen.v              (N,K)→冻结掩码
rtl/crc_gen.v                 CRC24B 串行 LFSR (POLY=0xB2B117)
rtl/polar_butterfly.v         纯蝶形 F^⊗n
rtl/code_block_concat.v       码块级联 (§6.9.1.5)
rtl/polar_encode_chain.v      ★链核 (分段/查表全规则 FSM)
rtl/polar_encode_stream.v     ★综合顶层 (串行装载封装)
constraints/polar_encode_stream.xdc   100MHz 起步约束
```

## 本次相对旧版的改动(按附录H金标准修正)
只动了 `polar_encode_chain.v` 一个文件,两处,均已回归+lint 通过:
1. **类型2末块**(`SA_PAD` 状态):消息不足时 **K=实际消息位、不补零**(旧版补零到表24-K)。
2. **R=1 无编码模式**(MCS8/12):加 `rate1` 旁路 —— 码块直传(不做极化变换)、
   块长=信息长。用 `rate1 ? 新 : 旧` 隔离,**R<1 路径逐字未变**。

面积增量可忽略(一处三行比较 + 一处旁路 mux,不加关键路径)。

## 验证状态(可对组员交代)
- 附录H 编码负载 **39/39 逐位符合标准**(真实 RTL 逐位对金标准 txPyLdC)。
- 回归全绿:base(589次编码)/crc/cat/chain(33例+附录A)/stream 全 PASS。
- Verilator `--lint-only -Wall`:顶层零告警,无 latch/组合环。

## Vivado 综合步骤
```tcl
read_verilog -sv [glob rtl/*.v]        ;# 或按 filelist.f 顺序
read_xdc constraints/polar_encode_stream.xdc
synth_design -top polar_encode_stream -part xc7a100t...   ;# 器件按实验室板卡
```
参考规模(旧版实测,本次改动增量可忽略):≈11300 LCs,F7≈2000,普通模式可上板。

## ★驱动注意(功能正确性关键)
- `crc_seed[23:0]`:**必须按每帧的 crcSeed 填**(附录H 里 32 位 crcSeed 取低 24 位)。
  这是码块 CRC24B 的种子;若固定成某个常数,非广播帧的编码会与标准不符。
- `B`=信息比特总长(=负载 txPyLd 长度,含 transport CRC);`mcs`=表22 索引 0..12;
  `ftype2`=1 类型2 / 0 类型3-4;消息经 `s_valid/s_bit` 逐位串行装入(a0 先)。

## 时序约束提示
XDC 现为 100MHz 起步 + 控制/状态口 false_path。若 `m_valid/m_bit` 以后要接同板
另一同步时钟域(如调制器),需把对应 false_path 换成真实 set_output_delay。

5. **消 `[Synth 8-7137]`(3 条)**:`code_block_concat.v` 的 `blk`/`elen`/`last_r`
   三个纯数据寄存器,原先待在带异步复位的 always 块内、但复位分支又没给它们赋值,
   Vivado 报 "Set 与 reset 同优先级,可能导致仿真与综合不一致"(**真实风险**,非
   风格告警)。 → 移到**独立无复位块**,装载条件仍为 `(st==IDLE && s_load)`,语义不变。

## 综合报告判读(2026-08-11 那轮)
- **时序已收敛且有余量**:WNS **+1.644ns** / WHS **+0.080ns** / **0 failing endpoints
  (共 20339)** / "All user specified timing constraints are met"。
  按 100MHz 算关键路径约 8.36ns,约合 **120MHz** 上限(28nm Artix-7 上;目标 16nm
  UltraScale+ 会更快)。
- **DRC 3 条(NSTD-1 / UCIO-1 / CFGBVS-1)可忽略** —— 都是"还没定板子、没分配引脚"
  的必然产物,**只在生成 bitstream 时才是硬拦路虎**。定板后在 XDC 里补
  `IOSTANDARD` / `PACKAGE_PIN` / `CFGBVS` 即可。
- **`[Vivado 12-7122]` Auto Incremental Compile 无参考检查点** —— 只是说这次跑的是
  完整流程而非增量,**无害**。
- ⚠️ **WHS 仍应以 implementation 后的报告为准**:综合阶段线延迟是估算值,hold 最
  依赖真实布线,布局布线阶段 Vivado 会主动插延迟修 hold(通常变好)。
