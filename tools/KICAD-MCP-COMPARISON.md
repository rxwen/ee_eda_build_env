# KiCad MCP 服务器对比：kicad-mcp-server vs Konnect

`init-eda-env.sh` 注册了两个 KiCad MCP 服务器。本文记录 2026-09-24 在本仓库上做的实测对比。

**结论：以 Konnect 为主。** kicad-mcp-server 的原理图写入会破坏已有连接，只宜保留它的少数只读工具。

## 测试环境

| | |
|---|---|
| 平台 | macOS arm64，KiCad 10.0.6 |
| kicad-mcp-server（`.mcp.json` 中的 `kicad`） | v2.8.1，`stable` 分支 |
| Konnect（`.mcp.json` 中的 `konnect`） | v0.12.1 |
| 测试工程 | `canmonitor_kicad`：39 个器件、29 个有效网络、42 个封装、4 层板 |

**方法**：用一个 MCP stdio 客户端直接驱动两个服务器，两边调用同名或同功能的工具，每边约 30 个。结果与 `kicad-cli` 的输出（netlist、ERC、DRC）比对。所有写操作都在工程副本上做，原工程文件测前测后哈希一致。

## 读取、检查、导出

| 测试项 | kicad-mcp-server | Konnect |
|---|---|---|
| 首次 `tools/list` | 一次暴露 244 个工具，schema 共 255KB（约 6 万 token） | 22 个，11KB；按需 `load_toolset`，全部加载后 234 个 |
| 启动 | Python 后端约 1 秒就绪，就绪前的调用直接报错，不排队 | 立即可用 |
| PCB 读取（板信息、器件、网络、层、走线） | 正确 | 正确，经 IPC 实时读取 |
| 原理图网络列表 | ❌ 漏掉 +3V3、VBUS、VISO（26/29） | ✅ 29/29 |
| 单个网络的引脚（GND） | ✅ 34/34 | ✅ 用 `get_net_components`；同名的 `get_net_connections` 只返回标签和坐标 |
| ERC | ✅ 0 条 | ✅ 0 条 |
| DRC | ✅ 5 条 | ✅ 5 条，并默认做原理图与 PCB 一致性检查（多报 39 条缺 MPN 字段，属实） |
| Gerber | ❌ `export_gerber`（走 SWIG）报告成功，但只写出钻孔文件；`export_gerbers`（走 kicad-cli）正常 | ✅ |
| BOM / 网表 | ✅ | ✅ BOM 正常；`export_netlist` 的参数名叫 `board`，但必须传 `.kicad_sch` |
| 速度 | 原理图查询 1–10 秒 | 多数在 10 毫秒以内 |

## 写入

测试操作：添加 R99，1 脚接 +3V3，2 脚接 LED_ACT；在 PCB 上把 R1 移动 2mm。

| | kicad-mcp-server | Konnect |
|---|---|---|
| R99 的连接 | 正确 | 正确 |
| 已有连接 | ❌ **每次 `connect_to_net` 都会删 junction（7 个只剩 1 个）**，CANH、CANL、EN、USB_DP 上 9 个引脚断开，ERC 从 0 条变成 10 条 | ✅ 原有网络全部不变，ERC 仍为 0。另在 3 处 T 形接点补画了 junction，不影响连接 |
| PCB 移动（板子未在 KiCad 中打开） | ✅ 需先 `open_project`，再 `save_board` | ✅ 自动改文件，并提示「请在 KiCad 中重新加载」 |

## Konnect 实时编辑（KiCad 开着副本板）

| 步骤 | 结果 |
|---|---|
| 移动、旋转器件，加走线、加过孔 | ✅ 走 IPC，每步 7–35 毫秒，KiCad 界面立即更新 |
| ⌘Z 撤销 | ✅ 每步编辑都是撤销历史里的独立一步 |
| 存盘前 | ✅ 板文件不变，改动只在 KiCad 内存里 |
| `save_project` 后 | ✅ 文件内容与 KiCad 中的状态一致；`kicad-cli` DRC 与 Konnect 报告一致 |

注意：移动器件时，连在它上面的走线不会跟着移动，这与在 KiCad 中按 M 移动的行为相同。AI 移完器件后需要重新布线，DRC 能查出由此造成的短路。

## 各自独有的功能

- **kicad-mcp-server**：器件外框（courtyard）重叠检查、自动布线、DigiKey 查询、KiCad GUI 自动化。
- **Konnect**：设计审查汇总（去耦、电源轨、短路、单引脚网络、BOM 健康度）、按 JLCPCB 规则做可制造性检查、原理图与 PCB 一致性检查、编辑器选择与交叉探测。

## 使用建议

- 原理图和 PCB 的编辑用 Konnect。
- 如保留 kicad-mcp-server，只用它的只读工具，例如器件外框重叠检查；不要用它的原理图写入工具。
- Konnect 不需要在 KiCad 插件管理器里安装插件，见 [README](README.md)。

## 未覆盖

两边的自动布线（依赖 Freerouting）、JLCPCB 离线库、层次原理图，以及 Windows 和 Linux 平台。
