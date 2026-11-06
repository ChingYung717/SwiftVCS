#!/bin/bash
# 端到端验证：建一个本地 SVN 仓库，把核心 9 项能力全部跑一遍。
# 完全离线（file:// 协议），不需要网络与凭据。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/svn_build_env.sh" || exit 1
if command -v brew >/dev/null 2>&1 && [ -d "$(brew --prefix subversion 2>/dev/null)/bin" ]; then
    SVN_BIN="$(brew --prefix subversion 2>/dev/null)/bin"
elif [ -d "/opt/homebrew/opt/subversion/bin" ]; then
    SVN_BIN="/opt/homebrew/opt/subversion/bin"
elif [ -d "/usr/local/opt/subversion/bin" ]; then
    SVN_BIN="/usr/local/opt/subversion/bin"
else
    SVN_BIN="$(dirname "$(command -v svn)")"
fi
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
BASE="$(mktemp -d "$TEMP_ROOT/swiftvcs-e2e.XXXXXXXX")" || exit 1
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$BASE" != "$TEMP_ROOT"/swiftvcs-e2e.* || -L "$BASE" ]] ||
       { [ -d "$BASE" ] && ! /usr/bin/find -P "$BASE" -depth -delete; }; then
        printf '无法清理本次测试目录：%s\n' "$BASE" >&2
        [ "$result" -ne 0 ] || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
export CFFIXED_USER_HOME="$BASE/home" HOME="$BASE/home"
mkdir -p "$HOME"
T="$BASE/swiftvcs-e2e"   # 注意：URL 里不能有双斜杠，路径必须规范
VCSCTL="$ROOT/.build/out/Products/Debug/vcsctl"
GUI="$ROOT/.build/out/Products/Debug/VCSExplorer"
if [ ! -x "$VCSCTL" ] || [ ! -x "$GUI" ]; then
    BIN_DIR="$(cd "$ROOT" && swift build --show-bin-path)"
    VCSCTL="$BIN_DIR/vcsctl"
    GUI="$BIN_DIR/VCSExplorer"
fi

PASS=0
FAIL=0
check() {  # check <描述> <期望包含> <实际输出>
    if echo "$3" | grep -q "$2"; then
        echo "  ✅ $1"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $1"
        echo "     期望包含: $2"
        echo "     实际: $3"
        FAIL=$((FAIL + 1))
    fi
}

echo "==> 准备本地仓库"
mkdir -p "$T" || exit 1
"$SVN_BIN/svnadmin" create "$T/repo"
"$SVN_BIN/svn" co "file://$T/repo" "$T/wc" >/dev/null
cd "$T/wc"
mkdir -p src docs
echo "hello v1" > src/main.txt
echo "# 说明" > docs/README.md
"$SVN_BIN/svn" add src docs >/dev/null
"$SVN_BIN/svn" commit -m "初始提交" >/dev/null
echo "hello v2" > src/main.txt
"$SVN_BIN/svn" commit -m "第二次提交" >/dev/null
cd "$ROOT"

echo
echo "==> 1 连接"
OUT=$("$VCSCTL" info "file://$T/repo" 2>&1)
check "返回仓库 UUID" "仓库 UUID" "$OUT"
check "返回最新修订" "最新修订 : r2" "$OUT"

echo "==> 2 浏览"
OUT=$("$VCSCTL" ls "file://$T/repo" 2>&1)
check "列出 src 目录" "src" "$OUT"
check "列出 docs 目录" "docs" "$OUT"
SUB_OUT=$("$VCSCTL" ls "file://$T/repo" src 2>&1)
check "浏览子目录返回完整相对路径" "src/main.txt" "$SUB_OUT"
CAT_OUT=$("$VCSCTL" cat "file://$T/repo" src/main.txt 2>&1)
check "读取远端文件内容 (cat)" "hello v2" "$CAT_OUT"

echo "==> 3 检出"
OUT=$("$VCSCTL" checkout "file://$T/repo" "$T/wc2" 2>&1)
check "检出成功" "已检出到" "$OUT"
check "工作副本文件存在" "x" "$([ -f "$T/wc2/src/main.txt" ] && echo x || echo no)"

echo "==> 5 状态与纳管 (add)"
echo "本地改动后的内容" > "$T/wc2/src/main.txt"   # 替换而非追加，差异应同时含增删行
echo "新文件" > "$T/wc2/src/newfile.txt"
ADD_OUT=$("$VCSCTL" add "$T/wc2" src/newfile.txt 2>&1)
check "纳入版本控制 (add)" "已纳入版本控制" "$ADD_OUT"
OUT=$("$VCSCTL" status "$T/wc2" 2>&1)
check "识别出修改" "修改" "$OUT"
check "识别出新增" "新增" "$OUT"
check "指出文件路径" "src/main.txt" "$OUT"

echo "==> 6 差异（含多文件）"
OUT=$("$VCSCTL" diff "$T/wc2" 2>&1)
check "差异含 hunk 头" "@@" "$OUT"
check "差异含新增行" "^+" "$OUT"
check "差异含删除行" "^-" "$OUT"
check "多文件差异包含新文件" "=== src/newfile.txt " "$OUT"
"$VCSCTL" revert "$T/wc2" src/newfile.txt >/dev/null 2>&1
rm -f "$T/wc2/src/newfile.txt"

echo "==> 7 提交"
OUT=$("$VCSCTL" commit "$T/wc2" src/main.txt -m "通过 vcsctl 提交" 2>&1)
check "提交成功" "已提交 r" "$OUT"
LOG=$("$SVN_BIN/svn" log -r HEAD "file://$T/repo" 2>&1)
check "提交说明已写入" "通过 vcsctl 提交" "$LOG"

echo "==> 8 回滚"
echo "要被回滚" >> "$T/wc2/docs/README.md"
OUT=$("$VCSCTL" revert "$T/wc2" docs/README.md 2>&1)
check "回滚执行" "已回滚" "$OUT"
OUT=$("$VCSCTL" status "$T/wc2" 2>&1)
check "回滚后不再有该改动" "工作副本干净" "$OUT"

echo "==> 9 历史"
OUT=$("$VCSCTL" log "$T/wc2" --limit 5 2>&1)
check "日志有修订号" "r3" "$OUT"
check "日志有作者" "$(id -un)" "$OUT"
check "日志有说明" "提交" "$OUT"

echo "==> 工作副本子目录与空提交"
SUB_LOG=$("$VCSCTL" log "$T/wc2/src" --limit 5 2>&1)
check "工作副本子目录返回历史" "r3" "$SUB_LOG"
BEFORE=$("$SVN_BIN/svnlook" youngest "$T/repo")
EMPTY=$("$VCSCTL" commit "$T/wc2" -m "不应产生修订" 2>&1)
AFTER=$("$SVN_BIN/svnlook" youngest "$T/repo")
check "空提交明确提示没有改动" "没有可提交的改动" "$EMPTY"
check "空提交未创建修订" "^$BEFORE$" "$AFTER"

echo "==> 4 同步"
OUT=$("$VCSCTL" update "$T/wc2" 2>&1)
check "同步成功" "已同步到" "$OUT"

echo "==> 10 提交级文件比对与分页 (vcsctl show & log)"
SHOW_M=$("$VCSCTL" show "file://$T/repo" 2 src/main.txt 2>&1)
check "修订级差异 (M) 含删除旧行" "^-hello v1" "$SHOW_M"
check "修订级差异 (M) 含新增新行" "^+hello v2" "$SHOW_M"

SHOW_A=$("$VCSCTL" show "file://$T/repo" 1 src/main.txt 2>&1)
check "新增文件 (A) 修订级差异展示全文新增" "^+hello v1" "$SHOW_A"

# 构造包含删除(D)、拷贝修改(A+)、中文 UTF-8 与二进制文件的 r4 提交
"$SVN_BIN/svn" cp "$T/wc2/docs/README.md" "$T/wc2/docs/README_copy.md" >/dev/null
echo "拷贝后新增一行" >> "$T/wc2/docs/README_copy.md"
echo "中文内容第一行" > "$T/wc2/docs/中文说明.txt"
printf '\x50\x4b\x03\x04\x00\x00\x80\xff' > "$T/wc2/src/lib.jar"
"$SVN_BIN/svn" add "$T/wc2/docs/中文说明.txt" "$T/wc2/src/lib.jar" >/dev/null
"$SVN_BIN/svn" rm "$T/wc2/src/main.txt" >/dev/null
"$SVN_BIN/svn" commit "$T/wc2" -m "r4: 测试删除、拷贝、中文与二进制" >/dev/null
"$SVN_BIN/svn" up "$T/wc2" >/dev/null

SHOW_D=$("$VCSCTL" show "file://$T/repo" 4 src/main.txt 2>&1)
check "删除文件 (D) 修订级差异展示全文删除" "^-本地改动后的内容" "$SHOW_D"

SHOW_CP=$("$VCSCTL" show "file://$T/repo" 4 docs/README_copy.md 2>&1)
check "拷贝并修改文件 (A+) 差异展示增量" "^+拷贝后新增一行" "$SHOW_CP"

SHOW_ZH=$("$VCSCTL" show "file://$T/repo" 4 "docs/中文说明.txt" 2>&1)
check "中文 UTF-8 新增文件差异正常解码" "中文内容第一行" "$SHOW_ZH"

SHOW_BIN=$("$VCSCTL" show "file://$T/repo" 4 src/lib.jar 2>&1)
check "二进制文件返回跳过比对提示" "二进制文件" "$SHOW_BIN"

PAGE_OUT=$("$VCSCTL" log "file://$T/repo" --limit 2 --revision 3 2>&1)
check "日志分页 (--limit + --revision) 返回指定起始修订" "r3 " "$PAGE_OUT"

# 回归测试：工作副本同时修改含 NUL 字节的二进制文件与后续文本文件时，diff 不应被截断丢失文本文件；以及 -m 以短横线开头的提交说明
printf '\x50\x4b\x03\x04\x00\x00\x99\xfe\x00\x01' > "$T/wc2/src/lib.jar"
echo "二进制共存时文本差异不丢失" >> "$T/wc2/docs/README.md"
MIX_DIFF=$("$VCSCTL" diff "$T/wc2" 2>&1)
check "工作副本含二进制与文本混合改动时不丢失文本差异" "二进制共存时文本差异不丢失" "$MIX_DIFF"

DASH_COMMIT=$("$VCSCTL" commit "$T/wc2" -m "-fix: 支持短横线开头的提交说明" 2>&1)
check "支持以 - 开头的提交说明参数 (-m \"-fix...\")" "已提交 r5" "$DASH_COMMIT"
DASH_LOG=$("$VCSCTL" log "file://$T/repo" --limit 1 2>&1)
check "日志包含以 - 开头的提交说明" "\\-fix: 支持短横线开头的提交说明" "$DASH_LOG"
"$SVN_BIN/svn" up "$T/wc2" >/dev/null

echo "==> 图形界面自检（与界面同一条模型路径）"
OUT=$("$GUI" --selftest "file://$T/repo" "$T/wc2" 2>&1)
check "界面自检连接" "✅ 连接" "$OUT"
check "界面自检浏览" "✅ 浏览子目录" "$OUT"
check "界面自检状态" "✅ 本地状态" "$OUT"
check "界面自检差异" "✅ 差异" "$OUT"
check "界面自检历史" "✅ 历史" "$OUT"
check "界面自检提交文件比对" "✅ 提交文件比对" "$OUT"
check "界面自检并排差异配对" "✅ 并排差异配对" "$OUT"

echo
echo "================================"
echo "  通过 $PASS 项，失败 $FAIL 项"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
python3 "$HERE/run_p0.py" "$VCSCTL" "$SVN_BIN"
