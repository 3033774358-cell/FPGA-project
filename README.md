# FPGA

FPGA 5G polar encode and decode

## 分支结构

按功能命名并使用前缀分组：

- `main`
- `develop` — 开发主线，功能分支开发完成后合并到这里
- `feature/polar-encoder` — Polar 编码器 RTL
- `feature/sc-decoder` — Polar SC 译码器 RTL
- `feature/scl` — SCL 译码器 RTL
- `feature/fast-ssc` — Fast-SSC 译码器小型验证工程
- `feature/fast-ssc-bram` — Fast-SSC 译码器 BRAM 面积优化版
- `hardware/fpga` — Vivado 综合脚本与约束
