# 验证方法

## 验证金字塔

1. **Python 参考模型**（`reference_encoder.py` 风格）：编码链（载荷 CRC24A/32 → 极化编码）、控制信道（CRC12/24B → 编码）。与规范附录 H 示例向量逐比特比对，载荷 44/44、控制 44/44 全部一致后才开始 RTL。
2. **Python 逐周期模型**（`sc_model.py` / `sc_fast_model.py` 风格）：逐拍复刻 controller + datapath + 存储器 + PE。baseline 与 pipelined 输出逐比特一致；Fast-SSC 768 用例 + 1140 组随机量化 LLR + 240 组零密集 corner case 全部 bit-exact。
3. **RTL 系统级 TB**：见下方回归矩阵。
4. **门级仿真**（目标器件环境）：综合/布线后网表 + 只驱动顶层端口的 TB。

## 回归矩阵（Vivado 2024.2 xsim，每个阶段全量重跑）

| TB | 覆盖 |
|---|---|
| `tb_llr_vec_bounds` | LLR 向量边界 |
| `sc_datapath_tb` | 数据通路单测（写回/采样时序按流水线调整） |
| `tb_fast_zero_fallback_64` | Rate-1 零 LLR fallback 正确触发 |
| `tb_256` | N=256 K=128，3 种信息位模式，层次化 shadow 检查 |
| `tb_1024` | N=1024 K=512，同上 |
| `sc_five_n_switch_tb` | N=64/128/256/512/1024 五码长切换 |

周期数基准（PASS 标准，逐拍一致）：

| 场景 | 周期 |
|---|---:|
| N=64 K=32 | 681 |
| N=128 K=64 | 1479 |
| N=256 K=128 | 3284 |
| N=512 K=256 | 7076 |
| N=1024 K=512（tb_1024） | 15606 |
| N=1024 K=512（switch TB） | 15526 |

## 纪律

- 每阶段全量回归，禁止只跑改动相关的 TB。
- 周期数必须逐拍一致，或按文档化原因变化（如流水线气泡 3N-2）。
- 内部信号检查（如 `u_datapath.u_sc_llr_mem...`）依赖 `ifndef SYNTHESIS` shadow 数组，只在 RTL 仿真有效。
- 门级仿真必须换用只驱动顶层端口的 TB：网表里寄存器改名、shadow 数组不存在，层次化引用会编译失败或失效。
- BRAM 未初始化读出 X 属预期行为，需与"写先于读"调度保证核对，不要当成单纯误报。

## 向量生成

- `verify/gen_vectors.py` 从附录 H 生成 `tv_payload_vectors.txt` / `tv_control_vectors.txt`。
- `verify/tv_vectors/` 下 44 条 TV：`TV<id>.cfg` / `.in.memh` / `.exp.memh`（LSB 优先，32bit hex）。
- 已知规范差异点：类型 2 末块 K=剩余比特（不补零）；R=1（MCS 8/12）直通不做极化扩展。
- 编码器与 SCL 译码器的兼容补丁在 `verify/rtl_fix/`，部署到 E 盘工程前需备份原文件。
