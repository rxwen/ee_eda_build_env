# tools/

## `init-eda-env.sh` — 初始化 AI 辅助 EDA 环境

把当前仓库配置成同时支持 **EasyEDA** 和 **KiCad** 的 AI 辅助设计环境。

```bash
bash tools/init-eda-env.sh              # 安装 + 校验（可重复执行）
bash tools/init-eda-env.sh --check      # 只校验，不改任何东西
bash tools/init-eda-env.sh --skip-jdk --skip-freerouting   # 不要自动布线
bash tools/init-eda-env.sh --skip-kicad-mcp --skip-konnect  # 不要 MCP 服务器
```

### 绿色安装

除 KiCad 本体（GUI 应用，只探测不安装）外，**所有依赖装在 `.claude/vendor/`**：

| 组件 | 体积 | 说明 |
|---|---|---|
| `pylibs/easyeda2kicad` | ~1MB | 按 LCSC 料号拉符号/封装/3D |
| `freerouting/*.jar` | ~61MB | 自动布线，取 GitHub 最新 Release |
| `jdk/` | ~300MB | Temurin，**仅当现有 JDK 版本不足时**才下载 |
| `kicad-happy/` | ~9MB | 只读审查技能，链接到 `.claude/skills/` |
| `bin/easyeda` | ~30MB | easyeda-agent CLI（经 `EASYEDA_INSTALL_DIR` 装进仓库） |
| `kicad-mcp-server/` | ~220MB | [KiCAD-MCP-Server](https://github.com/mixelpixx/KiCAD-MCP-Server)（`stable` 分支），venv 基于 KiCad 自带 Python；注册进 `.mcp.json` |
| `node/` | ~180MB | Node 22 LTS，**仅当现有 Node < 18 时**才下载 |
| `konnect/` | ~30MB | [Konnect](https://github.com/mixelpixx/Konnect) 单二进制（取最新 Release）+ 生成的 `konnect.toml`；JLCPCB 离线库也放这里 |

- **不碰 `~/.claude`**，不用 `/plugin install`（那是全局的）
- **不碰系统 pip**（用 `pip install --target`）
- 卸载 = `rm -rf .claude/vendor/`
- `.claude/vendor/` 已自动加进 `.gitignore`；换机器重跑脚本即可，无需把 400MB 提交进仓库

### 跨平台

| | macOS | Linux | Windows |
|---|---|---|---|
| 平台/架构探测 | ✅ arm64 / x64 | ✅ arm64 / x64 | ✅ Git Bash / WSL |
| KiCad 探测 | `.app` 内路径 | `/usr/bin`、Flatpak | `Program Files` |
| pcbnew 解释器 | KiCad 自带 Python.framework | 系统 python3 | KiCad 自带 python.exe |
| JDK 下载 | Adoptium mac/`ADOPT_ARCH` | Adoptium linux | Adoptium windows |
| 技能安装 | 符号链接 | 符号链接 | 符号链接失败时自动改为复制 |
| easyeda-agent | 官方 install.sh | 官方 install.sh | 需手工放 `.exe`（脚本会提示） |

### 产物：`.claude/vendor/tools.env`

脚本把探测到的路径写进这个文件，各构建脚本 source 它即可跨平台运行：

```bash
. "$(git rev-parse --show-toplevel)/.claude/vendor/tools.env"
"$KICAD_CLI" pcb drc --exit-code-violations board.kicad_pcb
"$KICAD_PY"  gen_pcb.py
"$JAVA_BIN" -jar "$FREEROUTING_JAR" -de board.dsn -do board.ses
```

`canmonitor_kicad/src/build.sh` 就是这么用的。

### 产物：`.mcp.json`（项目级 MCP）

脚本往仓库根的 `.mcp.json`（[project scope](https://code.claude.com/docs/en/mcp#project-scope)）注册两个
KiCad MCP 服务器，只增改这两项、保留其他服务器。里面是本机绝对路径，所以已加入 `.gitignore`，
每台机器由脚本各自生成。重启 Claude Code 后按提示批准，`/mcp` 查看连接状态。

| 服务器 | 项目 | 运行时 | 适用 |
|---|---|---|---|
| `kicad` | [KiCAD-MCP-Server](https://github.com/mixelpixx/KiCAD-MCP-Server) v2.x（MIT，稳定） | Node + KiCad 自带 Python（SWIG） | KiCad 9 / 10 |
| `konnect` | [Konnect](https://github.com/mixelpixx/Konnect)，前者的 Rust 继任者（AGPL-3.0，beta） | 单二进制，KiCad IPC API | 仅 KiCad 10 |

两者的实测对比见 [KICAD-MCP-COMPARISON.md](KICAD-MCP-COMPARISON.md)（结论：以 Konnect 为主）。两者都保留，不需要的用 `--skip-kicad-mcp` / `--skip-konnect` 跳过，
并从 `.mcp.json` 删掉对应项。

Konnect 的注意事项：

- 大多数 PCB 工具要求 KiCad 10 **开着目标板**，并勾选 Preferences → Plugins → **Enable KiCad API**。
  原理图编辑和 `kicad-cli` 导出不需要。
- **不必在 KiCad 插件管理器（PCM）里装 Konnect 插件**。插件只提供三样东西：一份随包附带的二进制
  （与 vendor 里的重复）、Tools 菜单里启停服务器的按钮（Claude Code 经 `.mcp.json` 自己启动），
  以及可选的原生 Specctra 导出桥（默认关闭，`export_specctra_dsn` 默认用内置 Rust 导出器）。
  只有想强制走 KiCad 原生 DSN 导出（`native_bridge_mode: "require"`）时才需要装。
- **不要运行 `konnect init`**，也不要在终端里不带参数运行 `konnect`：两者都会往全局 `~/.claude`
  装技能、agent 和 hook，和本仓库的项目级技能重复。
- 脚本通过 `--config .claude/vendor/konnect/konnect.toml` 指定配置，不读全局配置。
  但它的调用日志和运行状态（`logs/`、`run/`）在代码里写死在平台数据目录
  （macOS `~/Library/Application Support/konnect/`，Windows `%APPDATA%\konnect\`），是绿色安装唯一的例外。

### ⚠️ 脚本无法代劳的两件事

1. **KiCad 本体**要自己装（GUI 应用）。脚本探测不到会按你的系统给出安装提示。
2. **EasyEDA Pro 的连接器插件**必须在图形界面里装（立创插件市场搜
   `easyeda-agent-connector`，或侧载同兼容线的 `.eext`）。装完跑
   `easyeda update --check --exit-code && easyeda health` 确认。
