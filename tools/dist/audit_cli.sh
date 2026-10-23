#!/bin/sh
# CLI 体检：\`retouch-cli\`（批量/无头通路）。此前 preflight 只跑过它的 \`--model-check\`。
#
# 为什么需要它：CLI 是给批处理/脚本用的，**退出码就是它的接口** ——
# 而"\`--in\` 路径打错"原来会被 \`try?\` 吃掉，打印"输入 0 张 → 完成：成功 0 / 失败 0"并返回 0，
# 脚本与 CI 会当成跑成功（第 148 节修）。
#
# 判据：
#   A 正常批量：退出 0、产物存在、尺寸 == 原片、报告"成功 1 / 失败 0"
#   B 确定性：同样输入跑两次，产物**字节相同**
#   C \`--dry-run\` 不写盘（文档行为：只量不渲）
#   D 输入目录不存在 → **非零**退出
#   E 输入目录为空   → **非零**退出
#
#   F 与**基准哈希**逐字节一致（重构/拆分代码时的对照网，见下）
#
# F 的定位（省得被误用）：它比对的是"**同一台机器上、改动前后**的产物字节"。
# 跨机器/跨系统版本未必相同（PNG 编码器、ICC 处理会变），所以它不是跨环境校验，
# 而是"我改了代码，输出是否一个比特都没变"的那张网。
# 没有基准文件时 **判 F 失败**（没测到不算通过），用 --capture 建立。
#
# 用法：sh tools/dist/audit_cli.sh [夹具] ｜ sh tools/dist/audit_cli.sh --capture
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLI="$ROOT/app-retouch/.build/release/retouch-cli"
CAPTURE=0
if [ "${1:-}" = "--capture" ]; then CAPTURE=1; set --; fi
BASE="$ROOT/tools/dist/baselines/cli_export.sha256"
SRC="${1:-$ROOT/douyin_favorites/images/0001_7673816620465215714_01.webp}"
MAGICK=${MAGICK:-/opt/homebrew/bin/magick}

[ -x "$CLI" ] || { echo "先编译：cd app-retouch && swift build -c release"; exit 1; }
[ -f "$SRC" ] || { echo "缺夹具 $SRC —— 没测到不算通过"; exit 1; }

IN=/tmp/cli_in; OUTA=/tmp/cli_out_a; OUTB=/tmp/cli_out_b; OUTD=/tmp/cli_out_dry
rm -rf "$IN" "$OUTA" "$OUTB" "$OUTD"; mkdir -p "$IN"
cp "$SRC" "$IN/"

fail=0; pass=0
# ⚠️ 计数器**不能叫 n**：C 判据里 n 是"dry-run 写了几个文件"，同名会把计数清零
# （实测：6 条判据被报成 4 条）。
ok()   { pass=$((pass+1)); echo "  V $1"; }
bad()  { echo "  X $1"; fail=1; }

# A 正常批量
if "$CLI" --in "$IN" --out "$OUTA" --limit 1 > /tmp/cli_a.log 2>&1; then
    out=$(ls "$OUTA"/* 2>/dev/null | head -1)
    if [ -z "$out" ]; then bad "A 正常批量：没有产物"
    else
        want=$($MAGICK identify -format "%wx%h" "$SRC" 2>/dev/null || echo "?")
        got=$($MAGICK identify -format "%wx%h" "$out" 2>/dev/null || echo "?")
        if [ "$want" = "$got" ]; then ok "A 正常批量：退出 0、产物 ${got}（与原片一致）"
        else bad "A 正常批量：产物 ${got}，原片 $want"; fi
    fi
else
    bad "A 正常批量：退出码非 0（见 /tmp/cli_a.log）"
fi

if [ "$CAPTURE" = "1" ]; then
    a=$(ls "$OUTA"/* 2>/dev/null | head -1)
    [ -n "$a" ] || { echo "采集失败：没有产物"; exit 1; }
    mkdir -p "$(dirname "$BASE")"
    printf '%s  %s\n' "$(shasum -a 256 "$a" | awk '{print $1}')" "$(basename "$SRC")" > "$BASE"
    echo "已写入基准：$(cat "$BASE")"
    exit 0
fi

# B 确定性
if "$CLI" --in "$IN" --out "$OUTB" --limit 1 > /tmp/cli_b.log 2>&1; then
    a=$(ls "$OUTA"/* 2>/dev/null | head -1); b=$(ls "$OUTB"/* 2>/dev/null | head -1)
    if [ -n "$a" ] && [ -n "$b" ] && cmp -s "$a" "$b"; then
        ok "B 确定性：两次导出字节相同"
    else
        bad "B 确定性：两次导出不同（同输入同参数应一致）"
    fi
else
    bad "B 确定性：第二次运行退出码非 0"
fi

# C dry-run 不写盘
if "$CLI" --in "$IN" --out "$OUTD" --limit 1 --dry-run > /tmp/cli_c.log 2>&1; then
    n=$(ls "$OUTD" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" = "0" ]; then ok "C --dry-run：一个文件都没写"
    else bad "C --dry-run：写了 $n 个文件（应当只量不渲）"; fi
else
    bad "C --dry-run：退出码非 0"
fi

# D/E 错误输入必须非零退出
if "$CLI" --in /tmp/definitely_missing_dir_$$ --out /tmp/cli_never --limit 1 > /tmp/cli_d.log 2>&1; then
    bad "D 输入目录不存在：退出码是 0（脚本会误判成功）"
else
    ok "D 输入目录不存在：退出码非 0（$(tail -1 /tmp/cli_d.log | cut -c1-40)）"
fi
mkdir -p /tmp/cli_empty_$$
if "$CLI" --in /tmp/cli_empty_$$ --out /tmp/cli_never2 --limit 1 > /tmp/cli_e.log 2>&1; then
    bad "E 输入目录为空：退出码是 0"
else
    ok "E 输入目录为空：退出码非 0"
fi
rm -rf /tmp/cli_empty_$$

# F 与基准逐字节一致（重构/拆分代码的对照网）
a=$(ls "$OUTA"/* 2>/dev/null | head -1)
FIXNAME=$(basename "$SRC")
if [ -z "$a" ]; then bad "F 没有产物，无法比对基准"
elif [ ! -f "$BASE" ]; then
    bad "F 没有基准文件（tools/dist/baselines/cli_export.sha256）—— 没测到不算通过；用 sh tools/dist/audit_cli.sh --capture 建立"
else
    want_h=$(awk '{print $1}' "$BASE"); want_f=$(awk '{print $2}' "$BASE")
    if [ "$want_f" != "$FIXNAME" ]; then
        echo "  · F 跳过：基准是给 $want_f 的，本次夹具 ${FIXNAME}（换了夹具就不该比）"
    else
        got_h=$(shasum -a 256 "$a" | awk '{print $1}')
        if [ "$got_h" = "$want_h" ]; then ok "F 与基准逐字节一致（${FIXNAME}）"
        else bad "F 与基准不一致：期望 $(echo "$want_h" | cut -c1-12)… 实得 $(echo "$got_h" | cut -c1-12)…（代码改动改了输出）"; fi
    fi
fi

# G 全是坏文件 → 必须非零退出
# 为什么要有这条：批处理脚本凭退出码判断成败，而"成功 0 / 失败 4"原来也返回 0 ——
# 一个目录里全是坏文件（0 字节 / 半截 / 伪装成 .jpg 的文本 / 目录改后缀）时，
# 自动化会以为跑成功了（§176，同第 148 节那类"退出码不是接口"的毛病）。
BADIN=/tmp/cli_bad_in
rm -rf "$BADIN"; mkdir -p "$BADIN"
: > "$BADIN/zero.jpg"
printf 'not an image' > "$BADIN/text.jpg"
printf 'RIFF____WEBPVP8 ' > "$BADIN/half.webp"
mkdir -p "$BADIN/dir.jpg"
if "$CLI" --in "$BADIN" --out /tmp/cli_bad_out --limit 0 > /tmp/cli_g.log 2>&1; then
    bad "G 全是坏文件：退出码是 0（批处理会误判成功）"
else
    ok "G 全是坏文件：非零退出（$(tail -1 /tmp/cli_g.log | cut -c1-40)）"
fi
rm -rf "$BADIN" /tmp/cli_bad_out

echo "CLI 体检：$([ "$fail" = "0" ] && echo "$pass 条判据全部通过" || echo "有失败")"
exit $fail
