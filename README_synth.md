# synthesis 分支 — 综合脚本与约束

本分支集中存放编码器 / 译码器综合相关的脚本与约束，按模块分目录：

- `decode/` — SC 译码器（对应 `sc-decoder` 分支）综合脚本与约束
  - `synth_normal.tcl`：顶层 `sc_decode_stream` 普通综合脚本
  - `constraints/sc_decode_stream.xdc`：100MHz 起始时序约束
- `encode/` — Polar 编码器（对应 `encode` 分支）综合脚本与约束
  - `synth_normal.tcl`：顶层 `polar_encode_stream` 普通综合脚本
  - `constraints/polar_encode_stream.xdc`：100MHz 起始时序约束

## 使用方法

脚本中的 `read_verilog` / `read_xdc` 相对路径以综合包根目录为准：把对应目录下的
`synth_normal.tcl` 与 `constraints/` 放回对应代码分支的包根目录（即 `sc-decoder`
或 `encode` 分支根目录，与 `rtl_*` / `rtl` 同级），然后在同一目录运行：

```bash
vivado -mode batch -source synth_normal.tcl
```
