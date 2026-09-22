# tools/

## `init-eda-env.sh` — 初始化 AI 辅助 EDA 环境

把当前仓库配置成同时支持 **EasyEDA** 和 **KiCad** 的 AI 辅助设计环境。

```bash
bash tools/init-eda-env.sh              # 安装 + 校验（可重复执行）
bash tools/init-eda-env.sh --check      # 只校验，不改任何东西
bash tools/init-eda-env.sh --skip-jdk --skip-freerouting   # 不要自动布线
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

### ⚠️ 脚本无法代劳的两件事

1. **KiCad 本体**要自己装（GUI 应用）。脚本探测不到会按你的系统给出安装提示。
2. **EasyEDA Pro 的连接器插件**必须在图形界面里装（立创插件市场搜
   `easyeda-agent-connector`，或侧载同兼容线的 `.eext`）。装完跑
   `easyeda update --check --exit-code && easyeda health` 确认。
