#!/usr/bin/env bash
# ============================================================================
#  init-eda-env.sh —— 把当前仓库初始化为「EasyEDA + KiCad」AI 辅助设计环境
#
#  绿色安装：除 KiCad 本体（GUI 应用）外，一切装在仓库内的 .claude/vendor/，
#  不碰 ~/.claude、不碰系统 pip、不用 /plugin（那是全局的）。
#  删掉 .claude/vendor/ 即可完全卸载。
#
#  跨平台：macOS / Linux / Windows(Git Bash、WSL)
#
#  用法:
#    bash tools/init-eda-env.sh              # 安装 + 校验
#    bash tools/init-eda-env.sh --check      # 只校验，不改任何东西
#    bash tools/init-eda-env.sh --skip-jdk --skip-freerouting
#    bash tools/init-eda-env.sh --help
# ============================================================================
set -uo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────
KICAD_HAPPY_REPO="https://github.com/aklofas/kicad-happy.git"
KICAD_AUTHOR_REPO="${KICAD_AUTHOR_REPO:-https://github.com/rxwen/kicad-author.git}"
KICAD_HAPPY_SKILLS="kicad emc spice datasheets bom lcsc jlcpcb pcbway"
EASYEDA_INSTALL_URL="https://raw.githubusercontent.com/zhoushoujianwork/easyeda-agent/main/install.sh"
FREEROUTING_REPO="freerouting/freerouting"
JDK_FEATURE="25"          # Freerouting 2.4.x 需要的最低 JDK 主版本
PYLIBS="easyeda2kicad"

# ── 选项 ────────────────────────────────────────────────────────────────────
DO_CHECK_ONLY=0; SKIP_JDK=0; SKIP_FR=0; SKIP_EASYEDA=0; SKIP_SKILLS=0; SKIP_PY=0
for a in "$@"; do case "$a" in
  --check)            DO_CHECK_ONLY=1 ;;
  --skip-jdk)         SKIP_JDK=1 ;;
  --skip-freerouting) SKIP_FR=1; SKIP_JDK=1 ;;
  --skip-easyeda)     SKIP_EASYEDA=1 ;;
  --skip-kicad-skills) SKIP_SKILLS=1 ;;
  --skip-python)      SKIP_PY=1 ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "未知参数: $a （--help 看用法）" >&2; exit 2 ;;
esac; done

# ── 基础设施 ────────────────────────────────────────────────────────────────
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_OK=; C_WARN=; C_ERR=; C_DIM=; C_0=; }
ok()   { printf '  %s✓%s %s\n'  "$C_OK"   "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n'  "$C_WARN" "$C_0" "$*"; }
bad()  { printf '  %s✗%s %s\n'  "$C_ERR"  "$C_0" "$*"; }
note() { printf '    %s%s%s\n'  "$C_DIM"  "$*"  "$C_0"; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# 可移植 realpath（macOS 无 readlink -f）
abspath() ( cd "$(dirname "$1")" >/dev/null 2>&1 && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )

REPO="$(cd "$(dirname "$(abspath "$0")")/.." && pwd -P)"
VENDOR="$REPO/.claude/vendor"
SKILLS="$REPO/.claude/skills"
ENVFILE="$VENDOR/tools.env"

# 下载器：curl 优先，退回 wget
fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else return 127; fi
}
fetch_stdout() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 127; fi
}

# 链接（Windows/Git Bash 不支持符号链接时退回复制）
link_or_copy() { # link_or_copy <src> <dst>
  rm -rf "$2"
  if ln -s "$1" "$2" 2>/dev/null; then return 0; fi
  cp -R "$(cd "$(dirname "$2")" && cd "$(dirname "$1")" 2>/dev/null; echo "$1")" "$2" 2>/dev/null \
    || cp -R "$VENDOR/${1#../vendor/}" "$2"
}

# ── 1. 平台识别 ─────────────────────────────────────────────────────────────
head1 "1. 平台"
UNAME_S="$(uname -s)"; UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Darwin)                  OS=mac;     ADOPT_OS=mac ;;
  Linux)                   OS=linux;   ADOPT_OS=linux ;;
  MINGW*|MSYS*|CYGWIN*)    OS=windows; ADOPT_OS=windows ;;
  *) bad "不支持的系统: $UNAME_S"; exit 1 ;;
esac
case "$UNAME_M" in
  arm64|aarch64) ARCH=arm64; ADOPT_ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x64;   ADOPT_ARCH=x64 ;;
  *) bad "不支持的架构: $UNAME_M"; exit 1 ;;
esac
grep -qi microsoft /proc/version 2>/dev/null && note "检测到 WSL"
ok "$OS / $ARCH"
[ "$DO_CHECK_ONLY" = 1 ] || mkdir -p "$VENDOR" "$SKILLS"

# ── 2. KiCad（只探测，不安装）───────────────────────────────────────────────
head1 "2. KiCad"
KICAD_CLI=""; KICAD_PY=""
find_kicad() {
  local c
  for c in "$@"; do [ -x "$c" ] && { KICAD_CLI="$c"; return 0; }; done
  command -v kicad-cli >/dev/null 2>&1 && { KICAD_CLI="$(command -v kicad-cli)"; return 0; }
  return 1
}
case "$OS" in
  mac)   find_kicad /Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli ;;
  linux) find_kicad /usr/bin/kicad-cli /usr/local/bin/kicad-cli /var/lib/flatpak/exports/bin/org.kicad.KiCad ;;
  windows) find_kicad "/c/Program Files/KiCad/9.0/bin/kicad-cli.exe" \
                      "/c/Program Files/KiCad/10.0/bin/kicad-cli.exe" ;;
esac
if [ -n "$KICAD_CLI" ]; then
  KICAD_VER="$("$KICAD_CLI" version 2>/dev/null | head -1)"
  ok "kicad-cli $KICAD_VER"
  note "$KICAD_CLI"
  # 带 pcbnew 的解释器：先找 KiCad 自带的，再退回系统 python3
  case "$OS" in
    mac) for p in /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/*/Resources/Python.app/Contents/MacOS/Python; do
           [ -x "$p" ] && "$p" -c 'import pcbnew' >/dev/null 2>&1 && KICAD_PY="$p" && break
         done ;;
    windows) for p in "$(dirname "$KICAD_CLI")/python.exe"; do
           [ -x "$p" ] && "$p" -c 'import pcbnew' >/dev/null 2>&1 && KICAD_PY="$p" && break
         done ;;
  esac
  if [ -z "$KICAD_PY" ] && command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import pcbnew' >/dev/null 2>&1; then KICAD_PY="$(command -v python3)"; fi
  if [ -n "$KICAD_PY" ]; then
    ok "pcbnew 可用：$("$KICAD_PY" -c 'import pcbnew;print(pcbnew.GetBuildVersion())' 2>/dev/null)"
    note "$KICAD_PY"
  else
    warn "找不到能 import pcbnew 的解释器 —— PCB 生成/铺铜/DSN 导出不可用"
    case "$OS" in
      linux) note "Debian/Ubuntu: sudo apt install kicad  （Flatpak 版的 pcbnew 在沙箱内，需用 flatpak run）" ;;
      mac)   note "重装 KiCad 官方 .dmg 通常即可（自带 Python.framework）" ;;
    esac
  fi
else
  bad "未找到 kicad-cli —— KiCad 侧全部功能不可用"
  case "$OS" in
    mac)     note "https://www.kicad.org/download/macos/  （装官方 .dmg）" ;;
    linux)   note "sudo apt install kicad   或   flatpak install flathub org.kicad.KiCad" ;;
    windows) note "https://www.kicad.org/download/windows/" ;;
  esac
fi

# ── 3. Python 依赖（绿色，装进 vendor/pylibs）────────────────────────────────
head1 "3. Python 依赖（easyeda2kicad）"
PYLIBS_DIR="$VENDOR/pylibs"
PY3="$(command -v python3 || command -v python || true)"
if [ -z "$PY3" ]; then
  bad "未找到 python3 —— 无法安装 easyeda2kicad"
elif [ "$SKIP_PY" = 1 ]; then
  warn "按 --skip-python 跳过"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  PYTHONPATH="$PYLIBS_DIR" "$PY3" -c 'import easyeda2kicad' 2>/dev/null \
    && ok "easyeda2kicad 已就位" || bad "easyeda2kicad 未安装"
else
  if PYTHONPATH="$PYLIBS_DIR" "$PY3" -c 'import easyeda2kicad' 2>/dev/null; then
    ok "easyeda2kicad 已就位（跳过）"
  else
    mkdir -p "$PYLIBS_DIR"
    if "$PY3" -m pip install --quiet --upgrade --target "$PYLIBS_DIR" $PYLIBS 2>/dev/null; then
      ok "easyeda2kicad → .claude/vendor/pylibs/"
    else
      bad "pip 安装失败（无网络？）"
    fi
  fi
  note "用法: PYTHONPATH=.claude/vendor/pylibs python3 -m easyeda2kicad --full --lcsc_id=Cxxxxx --output lib/xx"
fi

# ── 4. JDK（仅当现有 JDK 版本不够时才下载）──────────────────────────────────
head1 "4. JDK（Freerouting 运行时）"
JAVA_BIN=""
jdk_major() { "$1" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/'; }
pick_java() {
  local c
  for c in "$VENDOR"/jdk/*/Contents/Home/bin/java "$VENDOR"/jdk/*/bin/java; do
    [ -x "$c" ] && { JAVA_BIN="$c"; return 0; }
  done
  command -v java >/dev/null 2>&1 && [ "$(jdk_major java)" -ge "$JDK_FEATURE" ] 2>/dev/null \
    && { JAVA_BIN="$(command -v java)"; return 0; }
  for c in /opt/homebrew/opt/openjdk*/bin/java /usr/lib/jvm/*/bin/java; do
    [ -x "$c" ] && [ "$(jdk_major "$c")" -ge "$JDK_FEATURE" ] 2>/dev/null && { JAVA_BIN="$c"; return 0; }
  done
  return 1
}
if [ "$SKIP_JDK" = 1 ]; then
  warn "按参数跳过"
elif pick_java; then
  ok "JDK $(jdk_major "$JAVA_BIN") — $JAVA_BIN"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  bad "无 JDK ≥ $JDK_FEATURE"
else
  note "现有 JDK 版本不足（Freerouting 需 ≥ $JDK_FEATURE），绿色下载 Temurin…"
  mkdir -p "$VENDOR/jdk"
  URL="https://api.adoptium.net/v3/binary/latest/${JDK_FEATURE}/ga/${ADOPT_OS}/${ADOPT_ARCH}/jdk/hotspot/normal/eclipse"
  TGZ="$VENDOR/jdk/_jdk.tar.gz"
  if fetch "$URL" "$TGZ" && tar xzf "$TGZ" -C "$VENDOR/jdk" 2>/dev/null; then
    rm -f "$TGZ"; pick_java && ok "Temurin JDK $(jdk_major "$JAVA_BIN") → .claude/vendor/jdk/" \
      || bad "解包后仍找不到 java"
  else
    rm -f "$TGZ"; bad "JDK 下载失败（无网络？可用 --skip-jdk 跳过）"
  fi
fi

# ── 5. Freerouting ──────────────────────────────────────────────────────────
head1 "5. Freerouting（自动布线）"
FR_JAR="$(ls "$VENDOR"/freerouting/freerouting-*.jar 2>/dev/null | head -1 || true)"
if [ "$SKIP_FR" = 1 ]; then
  warn "按参数跳过"
elif [ -n "$FR_JAR" ]; then
  ok "$(basename "$FR_JAR")"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  bad "未安装"
else
  mkdir -p "$VENDOR/freerouting"
  TAG="$(fetch_stdout "https://api.github.com/repos/$FREEROUTING_REPO/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$TAG" ]; then
    NAME="freerouting-${TAG#v}.jar"
    if fetch "https://github.com/$FREEROUTING_REPO/releases/download/$TAG/$NAME" \
             "$VENDOR/freerouting/$NAME"; then
      FR_JAR="$VENDOR/freerouting/$NAME"; ok "$NAME → .claude/vendor/freerouting/"
    else bad "jar 下载失败"; fi
  else bad "取不到 Freerouting 最新版本号（无网络？）"; fi
fi
if [ -n "$FR_JAR" ] && [ -n "$JAVA_BIN" ]; then
  if "$JAVA_BIN" -jar "$FR_JAR" --help >/dev/null 2>&1; then ok "Freerouting 可运行"
  else bad "Freerouting 跑不起来 —— JDK 版本可能仍不足"; fi
fi

# ── 6. kicad-happy 技能（项目级，不装全局）──────────────────────────────────
head1 "6. kicad-happy 审查技能（项目级）"
KH="$VENDOR/kicad-happy"
if [ "$SKIP_SKILLS" = 1 ]; then
  warn "按参数跳过"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  n=0; for s in $KICAD_HAPPY_SKILLS; do [ -e "$SKILLS/$s" ] && n=$((n+1)); done
  [ "$n" -gt 0 ] && ok "已链接 $n/$(echo $KICAD_HAPPY_SKILLS | wc -w | tr -d ' ') 个技能" || bad "未安装"
else
  if [ -d "$KH/.git" ]; then
    (cd "$KH" && git pull --quiet --ff-only 2>/dev/null) && ok "kicad-happy 已更新" || ok "kicad-happy 已存在"
  elif command -v git >/dev/null 2>&1 && git clone --depth 1 --quiet "$KICAD_HAPPY_REPO" "$KH" 2>/dev/null; then
    ok "kicad-happy 已克隆 → .claude/vendor/kicad-happy/"
  else
    bad "克隆失败（无 git 或无网络）"
  fi
  if [ -d "$KH/skills" ]; then
    n=0
    for s in $KICAD_HAPPY_SKILLS; do
      [ -d "$KH/skills/$s" ] || continue
      ( cd "$SKILLS" && rm -rf "$s" && { ln -s "../vendor/kicad-happy/skills/$s" "$s" 2>/dev/null \
        || cp -R "$KH/skills/$s" "$s"; } )
      n=$((n+1))
    done
    ok "项目级技能 $n 个：$KICAD_HAPPY_SKILLS"
    note "只写 <repo>/.claude/skills/，全局 ~/.claude 未改动"
  fi
fi

# ── 6b. kicad-author 绘图技能（项目级，不装全局）────────────────────────────
head1 "6b. kicad-author 绘图技能（项目级）"
KA="$VENDOR/kicad-author"
if [ "$SKIP_SKILLS" = 1 ]; then
  warn "按参数跳过"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  if [ -e "$SKILLS/kicad-author" ]; then
    ok "已链接"
    "$PY3" "$SKILLS/kicad-author/scripts/kicad-author" env >/dev/null 2>&1 \
      && ok "CLI 可运行" || bad "CLI 跑不起来"
  else
    bad "未安装"
  fi
else
  # 允许用本地工作副本开发：KICAD_AUTHOR_SRC=/path/to/kicad-author
  if [ -n "${KICAD_AUTHOR_SRC:-}" ] && [ -d "$KICAD_AUTHOR_SRC" ]; then
    ( cd "$SKILLS" && rm -rf kicad-author && ln -s "$KICAD_AUTHOR_SRC" kicad-author )
    ok "已链接本地副本 → $KICAD_AUTHOR_SRC"
  else
    if [ -d "$KA/.git" ]; then
      (cd "$KA" && git pull --quiet --ff-only 2>/dev/null) && ok "kicad-author 已更新" || ok "kicad-author 已存在"
    elif command -v git >/dev/null 2>&1 && git clone --depth 1 --quiet "$KICAD_AUTHOR_REPO" "$KA" 2>/dev/null; then
      ok "kicad-author 已克隆 → .claude/vendor/kicad-author/"
    else
      bad "克隆失败（无 git / 无网络 / 仓库尚未推送）"
      note "本地开发可用: KICAD_AUTHOR_SRC=/path/to/kicad-author bash tools/init-eda-env.sh"
    fi
    if [ -d "$KA/scripts" ]; then
      ( cd "$SKILLS" && rm -rf kicad-author && { ln -s "../vendor/kicad-author" kicad-author 2>/dev/null \
        || cp -R "$KA" kicad-author; } )
      ok "项目级技能 kicad-author（由代码生成可读的原理图 / 网表黄金表门禁）"
    fi
  fi
  if [ -e "$SKILLS/kicad-author" ]; then
    "$PY3" "$SKILLS/kicad-author/tests/test_units.py" >/dev/null 2>&1 \
      && ok "自带单元测试通过" || warn "单元测试未通过（功能可能受限）"
  fi
fi

# ── 7. easyeda-agent（EasyEDA 侧）───────────────────────────────────────────
head1 "7. easyeda-agent（EasyEDA 侧）"
EASYEDA_BIN=""
for c in "$VENDOR/bin/easyeda" "$VENDOR/bin/easyeda.exe"; do [ -x "$c" ] && EASYEDA_BIN="$c"; done
[ -z "$EASYEDA_BIN" ] && command -v easyeda >/dev/null 2>&1 && EASYEDA_BIN="$(command -v easyeda)"
if [ "$SKIP_EASYEDA" = 1 ]; then
  warn "按参数跳过"
elif [ -n "$EASYEDA_BIN" ]; then
  ok "$("$EASYEDA_BIN" --version 2>&1 | head -1)"
  note "$EASYEDA_BIN"
elif [ "$DO_CHECK_ONLY" = 1 ]; then
  bad "未安装"
elif [ "$OS" = windows ]; then
  warn "Windows 请手工下载 easyeda_windows_amd64.exe，改名 easyeda.exe 放进 .claude/vendor/bin/"
else
  mkdir -p "$VENDOR/bin"
  if fetch_stdout "$EASYEDA_INSTALL_URL" > "$VENDOR/_ee_install.sh" 2>/dev/null; then
    EASYEDA_INSTALL_DIR="$VENDOR/bin" bash "$VENDOR/_ee_install.sh" >/dev/null 2>&1
    rm -f "$VENDOR/_ee_install.sh"
    [ -x "$VENDOR/bin/easyeda" ] && { EASYEDA_BIN="$VENDOR/bin/easyeda"; ok "easyeda-agent → .claude/vendor/bin/"; } \
      || bad "安装脚本执行后仍未见二进制"
  else
    bad "下载安装脚本失败（无网络？）"
  fi
fi
if [ -n "$EASYEDA_BIN" ]; then
  note "⚠ 连接器插件必须在 EasyEDA Pro 图形界面里装，脚本无法代劳："
  note "  立创插件市场搜 easyeda-agent-connector，或侧载同兼容线的 .eext"
  note "  装完执行: easyeda update --check --exit-code && easyeda health"
fi
[ -d "$SKILLS/easyeda-agent" ] && ok "easyeda-agent 技能已在项目内" \
  || warn "未见 .claude/skills/easyeda-agent —— EasyEDA 侧技能需另行放置"

# ── 8. 写 tools.env ─────────────────────────────────────────────────────────
if [ "$DO_CHECK_ONLY" = 0 ]; then
  head1 "8. 生成 tools.env"
  {
    echo "# 由 tools/init-eda-env.sh 生成 —— 各脚本 source 它拿到跨平台路径，勿手改"
    echo "EDA_OS=$OS"; echo "EDA_ARCH=$ARCH"
    echo "REPO_ROOT=\"$REPO\""
    echo "VENDOR_DIR=\"$VENDOR\""
    echo "KICAD_CLI=\"${KICAD_CLI}\""
    echo "KICAD_PY=\"${KICAD_PY}\""
    echo "JAVA_BIN=\"${JAVA_BIN}\""
    echo "FREEROUTING_JAR=\"${FR_JAR}\""
    echo "EASYEDA_BIN=\"${EASYEDA_BIN}\""
    echo "PYLIBS_DIR=\"$PYLIBS_DIR\""
    echo "export PYTHONPATH=\"\$PYLIBS_DIR\${PYTHONPATH:+:\$PYTHONPATH}\""
  } > "$ENVFILE"
  ok "$ENVFILE"
  note "在脚本里: source \"\$(git rev-parse --show-toplevel)/.claude/vendor/tools.env\""

  # .gitignore：vendor 不进仓库（体积大且可重建）
  GI="$REPO/.gitignore"
  grep -qxF '.claude/vendor/' "$GI" 2>/dev/null || echo '.claude/vendor/' >> "$GI"
  grep -qxF '.claude/skills/kicad' "$GI" 2>/dev/null || {
    for s in $KICAD_HAPPY_SKILLS; do echo ".claude/skills/$s" >> "$GI"; done
  }
  grep -qxF '.claude/skills/kicad-author' "$GI" 2>/dev/null \
    || echo '.claude/skills/kicad-author' >> "$GI"
  ok ".gitignore 已排除 vendor 与由它派生的技能链接"
  note "换机器只需重跑本脚本，不必把 ~400MB 依赖提交进仓库"
fi

# ── 9. 汇总 ─────────────────────────────────────────────────────────────────
head1 "汇总"
st() { [ -n "$2" ] && printf '  %s%-22s%s %s\n' "$C_OK" "$1 ✓" "$C_0" "$3" \
                   || printf '  %s%-22s%s %s\n' "$C_ERR" "$1 ✗" "$C_0" "$3"; }
st "kicad-cli"      "$KICAD_CLI"    "${KICAD_VER:-未安装（KiCad 侧不可用）}"
st "pcbnew"         "$KICAD_PY"     "$([ -n "$KICAD_PY" ] && echo 可用 || echo '缺失：PCB 生成/铺铜/DSN 不可用')"
st "easyeda2kicad"  "$(PYTHONPATH=$PYLIBS_DIR $PY3 -c 'import easyeda2kicad' 2>/dev/null && echo y)" "LCSC 符号/封装/3D"
st "JDK"            "$JAVA_BIN"     "$([ -n "$JAVA_BIN" ] && jdk_major "$JAVA_BIN" || echo "需 ≥$JDK_FEATURE")"
st "Freerouting"    "$FR_JAR"       "自动布线"
st "kicad-happy"    "$([ -e "$SKILLS/kicad" ] && echo y)" "只读审查技能（项目级）"
st "kicad-author"    "$([ -e "$SKILLS/kicad-author" ] && echo y)" "原理图生成技能（项目级）"
st "easyeda-agent"  "$EASYEDA_BIN"  "EasyEDA 侧 CLI（连接器需 GUI 内装）"

printf '\n  占用: %s\n' "$(du -sh "$VENDOR" 2>/dev/null | cut -f1) （全部在 .claude/vendor/，删目录即卸载）"
if [ "$DO_CHECK_ONLY" = 0 ]; then
  printf '  下一步: %s\n' "bash tools/init-eda-env.sh --check   # 随时复核"
fi
