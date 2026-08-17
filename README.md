# FPGA

FPGA 5G polar encode and decode

## 分支结构

按功能命名并使用前缀分组（GitHub 分支列表会自动按前缀分组显示）：

- `main` — 稳定 / 发布版本，不直接开发
- `develop` — 开发主线，功能分支开发完成后合并到这里
- `feature/polar-encoder` — Polar 编码器 RTL（附录 H）
- `feature/sc-decoder` — Polar SC 译码器 RTL（含 testbench）
- `feature/fast-ssc` — Fast-SSC 译码器小型验证工程（rtl / tb / python）
- `hardware/fpga` — Vivado 综合脚本与约束（decode / encode 分目录）
